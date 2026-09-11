import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.jwm3000.bergfex-weather"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh(true)
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root). Open maps to the
  // panel's hotkey path so summoning suppresses the center hover reveal,
  // matching what the old per-plugin IpcHandler did.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  visible: panelLoader.item && panelLoader.item.label !== ""
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: panelLoader.item ? panelLoader.item.label : ""
    readonly property string temperature: panelLoader.item && panelLoader.item.showBarTemperature && panelLoader.item.reportTempNum !== "" ? panelLoader.item.reportTempNum + "°" : ""
    slotSize: Style.bar.statusSlot + (temperature !== "" ? temperatureMetrics.width + Style.space(6) : 0)
    TextMetrics {
      id: temperatureMetrics
      text: button.temperature
      font.family: button.fontFamily
      font.pixelSize: Style.font.body
    }
    iconComponent: Component {
      Row {
        anchors.centerIn: parent
        spacing: button.temperature !== "" ? Style.space(6) : 0
        OpticalGlyph {
          width: Style.bar.iconCanvas
          height: Style.bar.iconCanvas
          text: button.text
          fontFamily: button.fontFamily
          fontSize: Style.bar.iconFont
          color: button.foreground
          anchors.verticalCenter: parent.verticalCenter
        }
        Text {
          visible: button.temperature !== ""
          text: button.temperature
          textFormat: Text.PlainText
          font.family: button.fontFamily
          font.pixelSize: Style.font.body
          color: button.foreground
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }
    // Tooltip suppressed because the panel is the detail view.
    tooltipText: ""

    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.RightButton) panelLoader.item.openSource()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}
