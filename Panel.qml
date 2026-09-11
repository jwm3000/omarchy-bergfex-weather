import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "HelperLaunch.js" as HelperLaunch

Panel {
  id: root
  moduleName: "io.github.jwm3000.bergfex-weather"
  ipcTarget: "io.github.jwm3000.bergfex-weather"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: the popout coordinator (and with it the open-panel dot under the
  // pill) compares against `slot.activeItem`, and switchPanelFrom looks the
  // slot up the same way.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.refresh()
    // Set after showing, not before: showing hands the popout coordinator
    // over, which closes whichever panel was open, and that close clears the
    // shared flag. Deferring means the panel taking over always wins, while
    // a handoff to a panel that does not manage the flag still leaves it
    // cleared rather than stuck on.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (root.editingLocation) root.cancelEditingLocation()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  property bool showBarTemperature: false
  Process {
    id: preferencesProc
    command: HelperLaunch.command(root.helper, ["preferences"])
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          if (data.error) root.errorMessage = data.error
          else root.showBarTemperature = data.showBarTemperature === true
        } catch (e) { root.errorMessage = "Einstellung konnte nicht geladen werden." }
      }
    }
  }
  function toggleBarTemperature() {
    if (preferencesProc.running) return
    preferencesProc.command = HelperLaunch.command(root.helper, ["set-bar-temperature", showBarTemperature ? "false" : "true"])
    preferencesProc.running = true
  }
  property bool showNarrative: false
  property var report: null
  property string errorMessage: ""
  property string searchMessage: ""
  property bool editingLocation: false
  property bool savingLocation: false
  property var locationSuggestions: []
  property int suggestionIndex: 0
  property string geocodeActiveQuery: ""
  property string activeAction: ""
  readonly property string helper: decodeURIComponent(Qt.resolvedUrl("bergfex.py").toString().replace(/^file:\/\//, ""))
  readonly property string configuredLocation: report ? report.name : ""
  readonly property string label: report ? report.icon : ""
  readonly property var current: report
  readonly property var forecastDays: report ? report.days.slice(1, 4) : []
  readonly property string reportLocation: report ? report.name : "Ort auswählen"
  readonly property string reportTempNum: report ? String(Math.round(report.temperature)) : ""
  readonly property string tempUnit: "°C"
  readonly property string reportFeels: report ? report.rain : "—"
  readonly property string reportWind: report && report.days.length ? (report.days[0].wind || "—") : "—"
  readonly property string reportHumidity: report && report.days.length ? (report.days[0].sun || "—") : "—"

  function refresh(force) {
    if (forecastProc.running || savingLocation) return
    activeAction = "weather"
    forecastProc.command = HelperLaunch.command(helper, ["weather"])
    if (force === true) forecastProc.command = HelperLaunch.command(helper, ["weather", "--force"])
    forecastProc.running = true
  }

  function startEditingLocation() {
    editingLocation = true
    locationSuggestions = []
    searchMessage = "Mindestens 3 Zeichen oder Bergfex-Wetter-URL eingeben"
    suggestionIndex = 0
    Qt.callLater(function() {
      locationField.text = root.configuredLocation
      locationField.selectAll()
      locationField.forceActiveFocus()
    })
  }

  function cancelEditingLocation() {
    if (savingLocation) return
    editingLocation = false
    locationSuggestions = []
    geocodeDebounce.stop()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function commitLocation() {
    if (savingLocation || geocodeActiveQuery !== locationField.text.trim()) return
    if (locationSuggestions.length) pickSuggestion(locationSuggestions[suggestionIndex])
  }

  function clearLocation() { cancelEditingLocation() }

  function pickSuggestion(suggestion) {
    if (!suggestion || savingLocation || forecastProc.running) return
    savingLocation = true
    errorMessage = ""
    activeAction = "select"
    forecastProc.command = HelperLaunch.command(helper, ["select", suggestion.url])
    forecastProc.running = true
  }

  function requestGeocode() {
    if (!root.editingLocation || geocodeProc.running) return
    var query = locationField.text.trim()
    if (query.length < 3) {
      locationSuggestions = []
      searchMessage = "Mindestens 3 Zeichen eingeben"
      return
    }
    geocodeActiveQuery = query
    searchMessage = "Suche läuft…"
    geocodeProc.command = HelperLaunch.command(helper, ["search", query])
    geocodeProc.running = true
  }

  function dayName(dateString) {
    return Qt.locale("de_AT").toString(new Date(dateString + "T12:00:00"), "ddd")
  }
  function bareTempForDay(day, kind) { return day[kind] === null ? "—" : Math.round(day[kind]) + "°" }
  function dayIcon(day) { return day.icon }
  function openSource() {
    if (report) Qt.openUrlExternally(report.url)
    else startEditingLocation()
  }

  Process {
    id: forecastProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          root.savingLocation = false
          if (data.error) { root.errorMessage = data.error; return }
          if (data.report) {
            root.report = data.report
            root.errorMessage = data.report.warning || ""
            if (root.activeAction === "select") root.cancelEditingLocation()
          }
          if (data.needsLocation) root.errorMessage = "Klicke auf „Ort auswählen“, um zu starten."
        } catch (e) {
          root.savingLocation = false
          root.errorMessage = "Wetterdaten konnten nicht gelesen werden."
        }
      }
    }
    onExited: function(code) {
      root.savingLocation = false
      if (code === 124 || code === 137) root.errorMessage = "Zeitlimit beim Wetterabruf überschritten."
      if (code !== 0 && !root.errorMessage) root.errorMessage = "Bergfex-Abruf fehlgeschlagen."
    }
  }

  Process {
    id: geocodeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.editingLocation || root.geocodeActiveQuery !== locationField.text.trim()) return
        try {
          var data = JSON.parse(text)
          root.locationSuggestions = data.results || []
          root.searchMessage = data.error || (root.locationSuggestions.length ? "" : "Keine Orte gefunden. Versuche einen anderen Namen.")
          root.suggestionIndex = 0
        } catch (e) { root.searchMessage = "Ortssuche fehlgeschlagen." }
      }
    }
    onExited: function(code) {
      if (root.editingLocation && root.geocodeActiveQuery !== locationField.text.trim()) Qt.callLater(root.requestGeocode)
    }
  }
  Timer { id: geocodeDebounce; interval: 400; onTriggered: root.requestGeocode() }
  Timer { interval: 900000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function edit(): void { root.openFromHotkey(); root.startEditingLocation() }
    function toggleTemperature(): void { root.toggleBarTemperature() }
    function toggleReport(): void { root.showNarrative = !root.showNarrative; root.openFromHotkey() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(weatherColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLocation
      onReturnRequested: root.startEditingLocation()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: weatherScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: weatherColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: weatherColumn
          width: weatherScroll.width
          spacing: Style.space(14)

      // ---- Hero row: big icon + temp on the left; location and stats stacked on the right.
      Item {
        width: parent.width
        height: Math.max(heroLeft.height, heroRight.height)

        Row {
          id: heroLeft
          anchors.left: parent.left
          anchors.leftMargin: Style.space(16)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(16)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 5
            text: root.label || "—"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            // Decorative condition emoji; intentionally larger than the
            // Style.font.* scale's displayLarge (28).
            font.pixelSize: 64
          }

          Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            TapHandler {
              onTapped: root.showNarrative = !root.showNarrative
            }
            HoverHandler { cursorShape: Qt.PointingHandCursor }

            Text {
              id: tempBig
              textFormat: Text.PlainText
              text: root.reportTempNum || "—"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              // Hero temperature read-out; deliberately oversized, outside
              // the Style.font.* scale.
              font.pixelSize: 56
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              text: root.current ? root.tempUnit : ""
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.top: tempBig.top
              anchors.topMargin: Style.space(10)
            }
          }
        }

        Column {
          id: heroRight
          width: weatherStats.implicitWidth
          anchors.right: parent.right
          anchors.rightMargin: Style.space(20)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(12)

          Row {
            visible: !root.editingLocation && root.reportLocation !== ""
            spacing: Style.space(6)

            TapHandler {
              onTapped: root.startEditingLocation()
            }
            HoverHandler {
              cursorShape: Qt.PointingHandCursor
            }

            Text {
              text: ""  // nf-fa-map_marker
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              textFormat: Text.PlainText
              width: Style.space(250)
              elide: Text.ElideRight
              text: (root.reportLocation || "").toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              font.letterSpacing: 1
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Row {
            visible: root.editingLocation
            spacing: Style.space(6)

            TextField {
              id: locationField
              width: Style.space(190)
              enabled: !root.savingLocation
              placeholderText: "Ort suchen…"
              foreground: root.bar.foreground
              font.family: root.bar.fontFamily

              onTextChanged: if (root.editingLocation && !root.savingLocation) {
                root.locationSuggestions = []
                root.searchMessage = ""
                geocodeDebounce.restart()
              }

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.cancelEditingLocation()
                  event.accepted = true
                } else if (event.key === Qt.Key_Down) {
                  if (root.suggestionIndex < root.locationSuggestions.length - 1) root.suggestionIndex++
                  event.accepted = true
                } else if (event.key === Qt.Key_Up) {
                  if (root.suggestionIndex > 0) root.suggestionIndex--
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.commitLocation()
                  event.accepted = true
                }
              }
            }

            // Cancel location editing; show a spinner while the selection loads.
            Rectangle {
              width: Style.space(18)
              height: Style.space(18)
              anchors.verticalCenter: parent.verticalCenter
              radius: Math.min(4, Style.cornerRadius)
              color: !root.savingLocation && clearLocationArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: root.savingLocation ? "󰦖" : "✕"
                font.family: root.bar.fontFamily
                color: Qt.darker(root.bar.foreground, 1.4)
                font.pixelSize: Style.font.bodySmall

                RotationAnimator on rotation {
                  running: root.savingLocation
                  from: 0; to: 360
                  duration: 800
                  loops: Animation.Infinite
                }
              }

              MouseArea {
                id: clearLocationArea
                anchors.fill: parent
                enabled: !root.savingLocation
                hoverEnabled: true
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.clearLocation()
              }
            }
          }

          Row {
            id: weatherStats
            visible: !!root.current
            spacing: Style.space(22)

            Column {
              spacing: Style.space(5)
              Text {
                text: "REGEN"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              Text {
                textFormat: Text.PlainText
                text: root.reportFeels
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }
            }

            Column {
              spacing: Style.space(5)
              Text {
                text: "WIND · BFT"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              Text {
                textFormat: Text.PlainText
                text: root.reportWind
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }
            }

            Column {
              spacing: Style.space(5)
              Text {
                text: "SONNE"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              Text {
                textFormat: Text.PlainText
                text: root.reportHumidity
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }
            }
          }
        }
      }

      Item {
        visible: root.editingLocation
        width: parent.width
        height: barTemperatureSwitch.implicitHeight
        Text {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(16)
          anchors.right: barTemperatureSwitch.left
          anchors.verticalCenter: parent.verticalCenter
          text: "Temperatur in der Leiste"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
        }
        ToggleSwitch {
          id: barTemperatureSwitch
          anchors.right: parent.right
          anchors.rightMargin: Style.space(16)
          checked: root.showBarTemperature
          busy: preferencesProc.running
          foreground: root.bar.foreground
          onToggled: root.toggleBarTemperature()
        }
      }

      // ---- Geocoding suggestions while the location is being edited.
      Column {
        visible: root.editingLocation && !root.savingLocation && root.locationSuggestions.length > 0
        width: parent.width
        spacing: 0

        Repeater {
          model: root.locationSuggestions

          Rectangle {
            required property var modelData
            required property int index
            width: parent.width
            height: suggestionRow.implicitHeight + Style.space(12)
            radius: Style.cornerRadius
            color: index === root.suggestionIndex ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

            Column {
              id: suggestionRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.margins: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)
              Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: modelData.name
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: modelData.description
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onPositionChanged: root.suggestionIndex = index
              onClicked: root.pickSuggestion(modelData)
            }
          }
        }
      }

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        visible: text !== ""
        text: root.editingLocation ? (root.savingLocation ? "Standort wird geladen…" : root.searchMessage) : (root.errorMessage || (!root.current ? "Wetter wird geladen…" : ""))
        color: Qt.darker(root.bar.foreground, 1.5)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.italic: true
      }

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        visible: root.editingLocation && root.errorMessage !== ""
        text: root.errorMessage
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        visible: !!root.report
        text: root.report ? root.report.time + " · " + root.report.description + "\nBergfex · Abgerufen " + Qt.formatDateTime(new Date(root.report.fetchedAt * 1000), "dd.MM. HH:mm") + (root.report.stale ? " · VERALTET" : "") : ""
        color: Qt.darker(root.bar.foreground, 1.4)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        TapHandler { onTapped: root.openSource() }
        HoverHandler { cursorShape: Qt.PointingHandCursor }
      }

      // ---- Divider between current conditions and forecast.
      Rectangle {
        visible: root.forecastDays.length > 0
        width: parent.width
        height: Style.spacing.hairline
        color: root.bar.foreground
        opacity: 0.12
      }

      // ---- Forecast row: each cell has the day icon left of a day-name + hi/lo column.
      //      Wrapped in an Item so the block of cells can be centered within the popup.
      Item {
        visible: root.forecastDays.length > 0
        width: parent.width
        height: forecastRow.height

        Row {
          id: forecastRow
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(44)

          Repeater {
            model: root.forecastDays

            Row {
              required property var modelData
              required property int index
              spacing: Style.space(10)

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: root.dayIcon(modelData)
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.display
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  text: root.dayName(modelData.date).toUpperCase()
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }

                Row {
                  spacing: Style.space(6)

                  Text {
                    textFormat: Text.PlainText
                    text: root.bareTempForDay(modelData, "max")
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.bareTempForDay(modelData, "min")
                    color: Qt.darker(root.bar.foreground, 1.5)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                  }
                }
              }
            }
          }
        }
      }
      Column {
        width: parent.width
        visible: root.showNarrative
        spacing: Style.space(10)
        Rectangle {
          width: parent.width
          height: Style.spacing.hairline
          color: root.bar.foreground
          opacity: 0.12
        }
        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: root.report && root.report.narrative ? root.report.narrative.title : ""
          visible: text !== ""
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: root.report && root.report.narrative && root.report.narrative.text ? root.report.narrative.text : "Für diesen Ort ist derzeit kein Wetterbericht verfügbar."
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
        }
      }
    }
  }
  }
  }

}
