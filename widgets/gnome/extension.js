// Top bar label: time since the previous prayer and until the next one, with a menu to open or quit
// Salaat First (GNOME has no tray for its own menu). The app's helper (salaat-first-helper) rewrites
// widget.json with the day's times every 5 minutes.
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Pango from 'gi://Pango';
import Shell from 'gi://Shell';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const DATA = GLib.build_filenamev([GLib.get_user_cache_dir(), 'SalaatFirst', 'widget.json']);
const LINES = GLib.build_filenamev([GLib.get_user_config_dir(), 'SalaatFirst', 'widget-lines']);
const STYLE = 'font-feature-settings: "tnum"; text-align: right;';
// the helper writes these in the app's language and numerals; English until it has run once
const WORDS = {names: ['Fajr', 'Sunrise', 'Dhuhr', 'Asr', 'Maghrib', 'Ishaa'], until: '{p} in {t}', since: '{p} {t} ago', digits: '0123456789'};
const pad = n => String(n).padStart(2, '0');
const hms = s => `${pad(Math.floor(s / 3600))}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}`;
const stale = (day, now) => !day || new Date(now + day.offset * 1000).toISOString().slice(0, 10) !== day.date;

// same wrap-around as the app's header (today's Fajr stands in for tomorrow's)
function countdown(day, now) {
    const cur = Math.floor((now / 1000 + day.offset) % 86400);
    const secs = day.times.map(t => +t.slice(0, 2) * 3600 + +t.slice(3) * 60);
    const next = Math.max(0, secs.findIndex(s => s > cur));
    const prev = (next + 5) % 6;
    const passed = (cur - secs[prev] + 86400) % 86400;
    const left = (secs[next] - cur + 86400) % 86400;
    // an isolate keeps the sign left of the time, as in the app's header, when the name is Arabic
    const since = `${day.names[prev]} \u2066+${hms(passed)}\u2069`;
    const until = `${day.names[next]} \u2066-${hms(left)}\u2069`;
    // the app header's prayer: the previous one for 30 min after it, else the next
    const text = day.lines === 1
        ? (passed <= 1800 ? day.since.replace('{p}', day.names[prev]).replace('{t}', hms(passed))
            : day.until.replace('{p}', day.names[next]).replace('{t}', hms(left)))
        : (passed <= 1800 ? `${since}\n${until}` : `${until}\n${since}`);
    return text.replace(/[0-9]/g, d => day.digits[d]);
}

export default class SalaatFirst extends Extension {
    enable() {
        this._label = new St.Label({text: '…', y_align: Clutter.ActorAlign.CENTER, style: STYLE});
        this._button = new PanelMenu.Button(0.5, this.metadata.name);
        this._button.add_child(this._label);
        this._label.connect_after('style-changed', () => this._fit()); // St resets the attributes
        const menu = this._button.menu;
        // a running app only shows its window again
        menu.addAction('Open Salaat First', () => Shell.AppSystem.get_default().lookup_app('salaat-first.desktop')?.open_new_window(-1));
        menu.addAction('Quit Salaat First', () => Gio.Subprocess.new(['pkill', '-f', 'org.hicham.salaat.MainKt'], Gio.SubprocessFlags.NONE));
        menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        let two = false;
        try {
            two = new TextDecoder().decode(GLib.file_get_contents(LINES)[1]).trim() === '2';
        } catch {} // not set yet: one line
        this._two = new PopupMenu.PopupSwitchMenuItem('Two lines', two);
        this._two.connect('toggled', (item, on) => {
            GLib.mkdir_with_parents(GLib.path_get_dirname(LINES), 0o755);
            GLib.file_set_contents(LINES, on ? '2' : '1');
            this._fetch(Date.now());
        });
        menu.addMenuItem(this._two);
        Main.panel.addToStatusArea(this.uuid, this._button);
        this._fetched = 0;
        // the helper replaces the file: show a new city or day right away
        this._monitor = Gio.File.new_for_path(DATA).monitor_file(Gio.FileMonitorFlags.NONE, null);
        this._monitor.connect('changed', (m, f, o, event) => event === Gio.FileMonitorEvent.CHANGES_DONE_HINT && this._fetch(Date.now()));
        this._tick();
        this._timer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1000, () => this._tick());
    }

    disable() {
        GLib.source_remove(this._timer);
        this._monitor.cancel();
        this._button.destroy();
        this._button = this._label = this._two = this._day = this._monitor = null;
    }

    _tick() {
        const now = Date.now();
        // reread every 15 min, every minute while the day is missing or old (the app isn't running)
        if (now - this._fetched > (stale(this._day, now) ? 60e3 : 15 * 60e3)) this._fetch(now);
        if (this._day) this._label.text = countdown(this._day, now);
        return GLib.SOURCE_CONTINUE;
    }

    _fetch(now) {
        this._fetched = now;
        try {
            this._day = {...WORDS, ...JSON.parse(new TextDecoder().decode(GLib.file_get_contents(DATA)[1])), lines: this._two.state ? 2 : 1};
        } catch (e) {
            if (!e.matches?.(GLib.FileError, GLib.FileError.NOENT)) console.error(e); // no file: the app hasn't run yet
            return;
        }
        // two lines only fit the panel at 0.75em
        this._label.style = this._day.lines === 1 ? STYLE : `${STYLE} font-size: 0.75em;`;
        this._label.text = countdown(this._day, now);
        this._fit();
    }

    // Arabic fonts have taller lines: two of them overflow the panel, so tighten their line height to fit.
    // St keeps the label's style, color included, in these attributes; add to them.
    _fit() {
        const text = this._label.clutter_text;
        const attrs = text.get_attributes()?.copy() ?? new Pango.AttrList();
        attrs.change(Pango.attr_line_height_new(1));
        text.set_attributes(attrs);
        const [, height] = text.get_preferred_height(-1);
        if (height <= Main.panel.height) return;
        const fitted = attrs.copy(); // a new list: ClutterText ignores the one it already has
        fitted.change(Pango.attr_line_height_new(Main.panel.height / height));
        text.set_attributes(fitted);
    }
}
