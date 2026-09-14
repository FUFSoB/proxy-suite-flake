"""A tray icon over D-Bus: org.kde.StatusNotifierItem with a com.canonical.dbusmenu menu.

Hosts that show these: waybar, KDE Plasma, most wlroots bars, GNOME with the AppIndicator extension.
The menu is proxy_model's MenuItem tree; this module only speaks the protocols.
"""

import os

from gi.repository import Gio, GLib

WATCHER = "org.kde.StatusNotifierWatcher"
ITEM_PATH = "/StatusNotifierItem"
MENU_PATH = "/MenuBar"

ITEM_XML = """
<node>
  <interface name="org.kde.StatusNotifierItem">
    <property name="Category" type="s" access="read"/>
    <property name="Id" type="s" access="read"/>
    <property name="Title" type="s" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="WindowId" type="i" access="read"/>
    <property name="IconName" type="s" access="read"/>
    <property name="IconThemePath" type="s" access="read"/>
    <property name="IconPixmap" type="a(iiay)" access="read"/>
    <property name="OverlayIconName" type="s" access="read"/>
    <property name="OverlayIconPixmap" type="a(iiay)" access="read"/>
    <property name="AttentionIconName" type="s" access="read"/>
    <property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
    <property name="AttentionMovieName" type="s" access="read"/>
    <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    <property name="ItemIsMenu" type="b" access="read"/>
    <property name="Menu" type="o" access="read"/>
    <method name="ContextMenu"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    <method name="Activate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    <method name="SecondaryActivate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    <method name="Scroll"><arg name="delta" type="i" direction="in"/><arg name="orientation" type="s" direction="in"/></method>
    <signal name="NewTitle"/>
    <signal name="NewIcon"/>
    <signal name="NewAttentionIcon"/>
    <signal name="NewOverlayIcon"/>
    <signal name="NewToolTip"/>
    <signal name="NewStatus"><arg name="status" type="s"/></signal>
  </interface>
</node>
"""

MENU_XML = """
<node>
  <interface name="com.canonical.dbusmenu">
    <property name="Version" type="u" access="read"/>
    <property name="TextDirection" type="s" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="IconThemePath" type="as" access="read"/>
    <method name="GetLayout">
      <arg name="parentId" type="i" direction="in"/>
      <arg name="recursionDepth" type="i" direction="in"/>
      <arg name="propertyNames" type="as" direction="in"/>
      <arg name="revision" type="u" direction="out"/>
      <arg name="layout" type="(ia{sv}av)" direction="out"/>
    </method>
    <method name="GetGroupProperties">
      <arg name="ids" type="ai" direction="in"/>
      <arg name="propertyNames" type="as" direction="in"/>
      <arg name="properties" type="a(ia{sv})" direction="out"/>
    </method>
    <method name="GetProperty">
      <arg name="id" type="i" direction="in"/>
      <arg name="name" type="s" direction="in"/>
      <arg name="value" type="v" direction="out"/>
    </method>
    <method name="Event">
      <arg name="id" type="i" direction="in"/>
      <arg name="eventId" type="s" direction="in"/>
      <arg name="data" type="v" direction="in"/>
      <arg name="timestamp" type="u" direction="in"/>
    </method>
    <method name="EventGroup">
      <arg name="events" type="a(isvu)" direction="in"/>
      <arg name="idErrors" type="ai" direction="out"/>
    </method>
    <method name="AboutToShow">
      <arg name="id" type="i" direction="in"/>
      <arg name="needUpdate" type="b" direction="out"/>
    </method>
    <method name="AboutToShowGroup">
      <arg name="ids" type="ai" direction="in"/>
      <arg name="updatesNeeded" type="ai" direction="out"/>
      <arg name="idErrors" type="ai" direction="out"/>
    </method>
    <signal name="ItemsPropertiesUpdated">
      <arg name="updatedProps" type="a(ia{sv})"/>
      <arg name="removedProps" type="a(ias)"/>
    </signal>
    <signal name="LayoutUpdated">
      <arg name="revision" type="u"/>
      <arg name="parent" type="i"/>
    </signal>
    <signal name="ItemActivationRequested">
      <arg name="id" type="i"/>
      <arg name="timestamp" type="u"/>
    </signal>
  </interface>
</node>
"""


def item_properties(item):
    """dbusmenu properties of one MenuItem, as plain values."""
    if item.kind == "separator":
        return {"type": "separator"}
    props = {"label": item.label.replace("_", "__"), "enabled": item.enabled}
    if item.kind in ("check", "radio"):
        props["toggle-type"] = "checkmark" if item.kind == "check" else "radio"
        props["toggle-state"] = 1 if item.checked else 0
    if item.kind == "submenu":
        props["children-display"] = "submenu"
    return props


def _variant(value):
    kind = {bool: "b", int: "i", str: "s"}[type(value)]
    return GLib.Variant(kind, value)


class Menu:
    """The item ids a host sees stay put across updates: string ids map to the same numbers."""

    def __init__(self):
        self.numbers = {}  # MenuItem id -> dbusmenu id; 0 is the root
        self.items = {}  # dbusmenu id -> MenuItem
        self.children = {0: []}
        self.revision = 1
        self.shape = None

    def number(self, item_id):
        return self.numbers.setdefault(item_id, len(self.numbers) + 1)

    def update(self, tree):
        """Takes a new tree; True when anything a host shows changed."""
        items, children = {}, {0: []}

        def add(parent, nodes):
            for node in nodes:
                n = self.number(node.id)
                items[n] = node
                children[parent].append(n)
                children[n] = []
                add(n, node.children)

        add(0, tree)
        shape = (children, {n: item_properties(i) for n, i in items.items()})
        self.items, self.children = items, children
        if shape == self.shape:
            return False
        self.shape = shape
        self.revision += 1
        return True

    def properties(self, n, names=()):
        props = item_properties(self.items[n]) if n in self.items else {"children-display": "submenu"}
        return {k: _variant(v) for k, v in props.items() if not names or k in names}

    def layout(self, n, depth, names=()):
        kids = [] if depth == 0 else [
            GLib.Variant("(ia{sv}av)", self.layout(c, depth - 1, names)) for c in self.children.get(n, [])
        ]
        return (n, self.properties(n, names), kids)


class StatusNotifierItem:
    """Exports the icon and its menu on connection, and keeps it registered while a watcher runs.

    on_activate(): a click on the icon. on_menu(item): a menu item was clicked.
    on_available(bool): whether a host shows the icon.
    """

    def __init__(self, connection, app_id, title, icon_theme_path, on_activate, on_menu, on_available=None):
        self.connection = connection
        self.app_id, self.title, self.icon_theme_path = app_id, title, icon_theme_path
        self.on_activate, self.on_menu, self.on_available = on_activate, on_menu, on_available or (lambda _: None)
        self.icon, self.tooltip, self.status = "proxy-suite-disabled-unknown", "", "Active"
        self.menu = Menu()
        self.available = False
        self.name = f"org.kde.StatusNotifierItem-{os.getpid()}-1"
        # register_object_with_closures2 is GLib 2.84's; register_object is the older name for the same.
        register = getattr(connection, "register_object_with_closures2", None) or connection.register_object
        self.registrations = [
            register(ITEM_PATH, Gio.DBusNodeInfo.new_for_xml(ITEM_XML).interfaces[0], self._item_call, self._item_get, None),
            register(MENU_PATH, Gio.DBusNodeInfo.new_for_xml(MENU_XML).interfaces[0], self._menu_call, self._menu_get, None),
        ]
        self.owner = Gio.bus_own_name_on_connection(connection, self.name, Gio.BusNameOwnerFlags.NONE, None, None)
        self.watch = Gio.bus_watch_name_on_connection(
            connection, WATCHER, Gio.BusNameWatcherFlags.NONE, self._watcher_appeared, self._watcher_vanished
        )

    def close(self):
        Gio.bus_unwatch_name(self.watch)
        Gio.bus_unown_name(self.owner)
        for r in self.registrations:
            self.connection.unregister_object(r)

    # --- what the app changes -----------------------------------------------------

    def update(self, icon, tooltip, tree, attention=False):
        if icon != self.icon:
            self.icon = icon
            self._emit(ITEM_PATH, "org.kde.StatusNotifierItem", "NewIcon")
        if tooltip != self.tooltip:
            self.tooltip = tooltip
            self._emit(ITEM_PATH, "org.kde.StatusNotifierItem", "NewToolTip")
        status = "NeedsAttention" if attention else "Active"
        if status != self.status:
            self.status = status
            self._emit(ITEM_PATH, "org.kde.StatusNotifierItem", "NewStatus", GLib.Variant("(s)", (status,)))
        if self.menu.update(tree):
            self._emit(MENU_PATH, "com.canonical.dbusmenu", "LayoutUpdated", GLib.Variant("(ui)", (self.menu.revision, 0)))

    def _emit(self, path, interface, signal, args=None):
        try:
            self.connection.emit_signal(None, path, interface, signal, args)
        except GLib.Error:
            pass  # the bus went away: nothing shows the icon anyway

    # --- registration ---------------------------------------------------------------

    def _watcher_appeared(self, connection, name, owner):
        # A bar that restarts brings a new watcher: register again each time.
        connection.call(
            WATCHER, "/StatusNotifierWatcher", WATCHER, "RegisterStatusNotifierItem",
            GLib.Variant("(s)", (self.name,)), None, Gio.DBusCallFlags.NONE, -1, None, self._registered,
        )

    def _registered(self, connection, result):
        try:
            connection.call_finish(result)
        except GLib.Error:
            self._set_available(False)
        else:
            self._set_available(True)

    def _watcher_vanished(self, connection, name):
        self._set_available(False)

    def _set_available(self, available):
        if available != self.available:
            self.available = available
            self.on_available(available)

    # --- org.kde.StatusNotifierItem ---------------------------------------------------

    def _item_get(self, connection, sender, path, interface, prop):
        values = {
            "Category": ("s", "SystemServices"),
            "Id": ("s", self.app_id),
            "Title": ("s", self.title),
            "Status": ("s", self.status),
            "WindowId": ("i", 0),
            "IconName": ("s", self.icon),
            "IconThemePath": ("s", self.icon_theme_path),
            "IconPixmap": ("a(iiay)", []),
            "OverlayIconName": ("s", ""),
            "OverlayIconPixmap": ("a(iiay)", []),
            "AttentionIconName": ("s", self.icon),
            "AttentionIconPixmap": ("a(iiay)", []),
            "AttentionMovieName": ("s", ""),
            "ToolTip": ("(sa(iiay)ss)", (self.icon, [], self.title, self.tooltip)),
            "ItemIsMenu": ("b", False),
            "Menu": ("o", MENU_PATH),
        }
        return GLib.Variant(*values[prop]) if prop in values else None

    def _item_call(self, connection, sender, path, interface, method, params, invocation):
        if method in ("Activate", "SecondaryActivate"):
            GLib.idle_add(self.on_activate)
        invocation.return_value(None)

    # --- com.canonical.dbusmenu ---------------------------------------------------------

    def _menu_get(self, connection, sender, path, interface, prop):
        values = {
            "Version": ("u", 3),
            "TextDirection": ("s", "ltr"),
            "Status": ("s", "normal"),
            "IconThemePath": ("as", [self.icon_theme_path] if self.icon_theme_path else []),
        }
        return GLib.Variant(*values[prop]) if prop in values else None

    def _menu_call(self, connection, sender, path, interface, method, params, invocation):
        args = params.unpack()
        menu = self.menu
        if method == "GetLayout":
            parent, depth, names = args
            invocation.return_value(GLib.Variant("(u(ia{sv}av))", (menu.revision, menu.layout(parent, depth, names))))
        elif method == "GetGroupProperties":
            ids, names = args
            found = [(n, menu.properties(n, names)) for n in ids if n in menu.items] if ids else [
                (n, menu.properties(n, names)) for n in menu.items
            ]
            invocation.return_value(GLib.Variant("(a(ia{sv}))", (found,)))
        elif method == "GetProperty":
            n, name = args
            value = menu.properties(n).get(name)
            if value is None:
                invocation.return_dbus_error("com.canonical.dbusmenu.Error", f"no property {name} on {n}")
            else:
                invocation.return_value(GLib.Variant("(v)", (value,)))
        elif method == "Event":
            self._event(*args[:2])
            invocation.return_value(None)
        elif method == "EventGroup":
            errors = [n for n, event, _, _ in args[0] if not self._event(n, event)]
            invocation.return_value(GLib.Variant("(ai)", (errors,)))
        elif method == "AboutToShow":
            invocation.return_value(GLib.Variant("(b)", (False,)))
        elif method == "AboutToShowGroup":
            invocation.return_value(GLib.Variant("(aiai)", ([], [n for n in args[0] if n and n not in menu.items])))
        else:
            invocation.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", method)

    def _event(self, n, event):
        item = self.menu.items.get(n)
        if item is None:
            return False
        if event == "clicked" and item.enabled and item.kind not in ("separator", "submenu"):
            GLib.idle_add(self.on_menu, item)
        return True
