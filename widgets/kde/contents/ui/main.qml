// Panel label: time since the previous prayer and until the next one, with right-click actions to open
// or quit Salaat First. The app's helper (salaat-first-helper) rewrites widget.json with the day's
// times every 5 minutes.
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root
    // the helper writes these in the app's language and numerals; English until it has run once
    readonly property var words: ({ names: ["Fajr", "Sunrise", "Dhuhr", "Asr", "Maghrib", "Ishaa"], until: "{p} in {t}", since: "{p} {t} ago", digits: "0123456789" })
    readonly property bool twoLines: Plasmoid.configuration.twoLines
    property var day: null
    property double fetched: 0
    property string label: "…"

    // inline in the panel: Plasma 6 treats a plasmoid with no full view as always expanded and never shows its compact view
    preferredRepresentation: fullRepresentation
    fullRepresentation: PlasmaComponents.Label {
        text: root.label
        // two lines only fit the panel in the small font
        font.pointSize: root.twoLines ? Kirigami.Theme.smallFont.pointSize : Kirigami.Theme.defaultFont.pointSize
        // Arabic's taller lines overflow the widget: center them so the second one stays on the panel
        verticalAlignment: Text.AlignVCenter
        font.features: { "tnum": 1 }
        horizontalAlignment: Text.AlignRight
        Layout.minimumWidth: implicitWidth
    }

    Plasmoid.contextualActions: [
        // a running app only shows its window again
        PlasmaCore.Action { text: "Open Salaat First"; icon.name: "salaat-first"; onTriggered: shell.connectSource("salaat-first >/dev/null 2>&1 &") },
        // and its native notifications' timers, which outlive it
        PlasmaCore.Action { text: "Quit Salaat First"; icon.name: "application-exit"; onTriggered: shell.connectSource("pkill -f org.hicham.salaat.MainKt; systemctl --user stop 'salaat-first-notification-*.timer'") },
        PlasmaCore.Action { text: "Two lines"; checkable: true; checked: root.twoLines; onTriggered: Plasmoid.configuration.twoLines = checked }
    ]

    onTwoLinesChanged: if (day) label = countdown(Date.now())

    function pad(n) { return String(n).padStart(2, "0") }
    function hms(s) { return `${pad(Math.floor(s / 3600))}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}` }
    function stale(now) { return !day || new Date(now + day.offset * 1000).toISOString().slice(0, 10) !== day.date }

    // same wrap-around as the app's header (today's Fajr stands in for tomorrow's)
    function countdown(now) {
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
        const text = !twoLines
            ? (passed <= 1800 ? day.since.replace("{p}", day.names[prev]).replace("{t}", hms(passed))
                : day.until.replace("{p}", day.names[next]).replace("{t}", hms(left)))
            : (passed <= 1800 ? `${since}\n${until}` : `${until}\n${since}`);
        return text.replace(/[0-9]/g, d => day.digits[d]);
    }

    function tick() {
        const now = Date.now();
        // reread every 5 min (the helper's interval), every minute while the day is missing or old
        if (now - fetched > (stale(now) ? 60e3 : 5 * 60e3)) {
            fetched = now;
            shell.connectSource('cat "${XDG_CACHE_HOME:-$HOME/.cache}/SalaatFirst/widget.json"');
        }
        if (day) label = countdown(now);
    }

    P5Support.DataSource {
        id: shell
        engine: "executable"
        onNewData: (source, data) => {
            disconnectSource(source);
            if (source.startsWith("cat ") && data["exit code"] === 0) {
                root.day = Object.assign({}, root.words, JSON.parse(data.stdout));
                root.tick();
            }
        }
    }

    Timer { interval: 1000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.tick() }
}
