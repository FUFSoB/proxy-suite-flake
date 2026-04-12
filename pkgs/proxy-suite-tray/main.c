#include <gtk/gtk.h>
#include <gio/gio.h>
#include <libayatana-appindicator/app-indicator.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef POLL_INTERVAL
#define POLL_INTERVAL 5
#endif
#ifndef SYSTEMCTL_BIN
#define SYSTEMCTL_BIN "/run/current-system/sw/bin/systemctl"
#endif
#ifndef PKEXEC_BIN
#define PKEXEC_BIN "/run/current-system/sw/bin/pkexec"
#endif

static AppIndicator *indicator;
static GtkWidget *menu;
static GtkWidget *status_item;
static GtkWidget *proxy_item;
static GtkWidget *tproxy_item;
static GtkWidget *tun_item;
static GtkWidget *open_controls_item;
static GtkWidget *controls_window;
static GtkWidget *controls_status_label;
static GtkWidget *controls_proxy_button;
static GtkWidget *controls_tproxy_button;
static GtkWidget *controls_tun_button;

static gboolean command_succeeds(gchar **argv) {
    GError *error = NULL;
    gint wait_status = 0;

    if (!g_spawn_sync(NULL, argv, NULL, G_SPAWN_STDERR_TO_DEV_NULL, NULL, NULL, NULL, NULL, &wait_status, &error)) {
        g_clear_error(&error);
        return FALSE;
    }

    if (!g_spawn_check_wait_status(wait_status, &error)) {
        g_clear_error(&error);
        return FALSE;
    }

    return TRUE;
}

static gboolean command_stdout(gchar **argv, gchar **stdout_text) {
    GError *error = NULL;
    gint wait_status = 0;

    *stdout_text = NULL;
    if (!g_spawn_sync(NULL, argv, NULL, G_SPAWN_STDERR_TO_DEV_NULL, NULL, NULL, stdout_text, NULL, &wait_status, &error)) {
        g_clear_error(&error);
        return FALSE;
    }

    if (!g_spawn_check_wait_status(wait_status, &error)) {
        g_clear_error(&error);
        g_clear_pointer(stdout_text, g_free);
        return FALSE;
    }

    return TRUE;
}

static gboolean on_controls_delete(GtkWidget *widget, GdkEvent *event, gpointer data) {
    (void)event; (void)data;
    gtk_widget_hide(widget);
    return TRUE;
}

static void on_close_controls(GtkWidget *item, gpointer data) {
    (void)item; (void)data;
    if (controls_window) {
        gtk_widget_hide(controls_window);
    }
}

static void on_open_controls(GtkWidget *item, gpointer data);

static gboolean on_open_controls_idle(gpointer data) {
    (void)data;
    on_open_controls(NULL, NULL);
    return G_SOURCE_REMOVE;
}

static GDBusMessage *on_session_bus_message(
    GDBusConnection *connection,
    GDBusMessage *message,
    gboolean incoming,
    gpointer user_data
) {
    (void)connection; (void)user_data;
    if (!incoming || !message) {
        return message;
    }
    if (g_dbus_message_get_message_type(message) != G_DBUS_MESSAGE_TYPE_METHOD_CALL) {
        return message;
    }

    const gchar *iface = g_dbus_message_get_interface(message);
    const gchar *member = g_dbus_message_get_member(message);
    const gchar *path = g_dbus_message_get_path(message);

    if (iface && member && path &&
        strcmp(iface, "org.kde.StatusNotifierItem") == 0 &&
        strcmp(member, "Activate") == 0 &&
        g_str_has_prefix(path, "/org/ayatana/NotificationItem/")) {
        g_idle_add(on_open_controls_idle, NULL);
    }

    return message;
}

static gboolean service_exists(const char *name) {
    gchar *load_state = NULL;
    gboolean exists = FALSE;
    gchar *argv[] = {
        (gchar *) SYSTEMCTL_BIN,
        (gchar *) "show",
        (gchar *) "--value",
        (gchar *) "--property=LoadState",
        NULL,
        NULL
    };

    argv[4] = g_strdup_printf("%s.service", name);
    if (command_stdout(argv, &load_state)) {
        g_strstrip(load_state);
        exists = load_state[0] != '\0' && strcmp(load_state, "not-found") != 0;
    }

    g_free(argv[4]);
    g_free(load_state);
    return exists;
}

static gboolean service_active(const char *name) {
    gchar *argv[] = {
        (gchar *) SYSTEMCTL_BIN,
        (gchar *) "is-active",
        (gchar *) "--quiet",
        NULL,
        NULL
    };

    argv[3] = g_strdup_printf("%s.service", name);
    gboolean active = command_succeeds(argv);
    g_free(argv[3]);
    return active;
}

static gboolean run_privileged(const char *action, const char *service) {
    char cmd[512];

    snprintf(
        cmd,
        sizeof(cmd),
        "%s %s %s %s.service",
        PKEXEC_BIN,
        SYSTEMCTL_BIN,
        action,
        service
    );

    return system(cmd) == 0;
}

static const char *pick_icon_name(
    const char *const *candidates,
    gsize candidates_len,
    const char *fallback
) {
    GtkIconTheme *theme = gtk_icon_theme_get_default();
    if (!theme) {
        return fallback;
    }

    for (gsize i = 0; i < candidates_len; ++i) {
        if (gtk_icon_theme_has_icon(theme, candidates[i])) {
            return candidates[i];
        }
    }

    return fallback;
}

static void update_status(void) {
    gboolean socks = service_active("proxy-suite-socks");
    gboolean tproxy = service_active("proxy-suite-tproxy");
    gboolean tun = service_active("proxy-suite-tun");

    static const char *const active_icons[] = {
        "network-vpn",
        "network-vpn-symbolic"
    };
    static const char *const partial_icons[] = {
        "network-vpn-acquiring",
        "network-vpn",
        "network-vpn-acquiring-symbolic",
        "network-vpn-symbolic"
    };
    static const char *const disconnected_icons[] = {
        "network-vpn-disconnected",
        "network-offline",
        "network-error",
        "process-stop",
        "dialog-error",
        "network-vpn-disconnected-symbolic",
        "network-offline-symbolic",
        "network-error-symbolic",
        "process-stop-symbolic",
        "dialog-error-symbolic"
    };

    if (socks) {
        if (tproxy || tun) {
            app_indicator_set_icon(
                indicator,
                pick_icon_name(active_icons, G_N_ELEMENTS(active_icons), "network-vpn")
            );
        } else {
            app_indicator_set_icon(
                indicator,
                pick_icon_name(partial_icons, G_N_ELEMENTS(partial_icons), "network-vpn-acquiring")
            );
        }
    } else {
        app_indicator_set_icon(
            indicator,
            pick_icon_name(disconnected_icons, G_N_ELEMENTS(disconnected_icons), "network-vpn-disconnected")
        );
    }

    gtk_menu_item_set_label(GTK_MENU_ITEM(status_item),
        socks ? "SOCKS Proxy: Running" : "SOCKS Proxy: Stopped");
    if (controls_status_label) {
        gtk_label_set_text(GTK_LABEL(controls_status_label),
            socks ? "SOCKS Proxy: Running" : "SOCKS Proxy: Stopped");
    }
    if (proxy_item) {
        gtk_menu_item_set_label(GTK_MENU_ITEM(proxy_item),
            socks ? "Disable Proxy" : "Enable Proxy");
    }
    if (controls_proxy_button) {
        gtk_button_set_label(GTK_BUTTON(controls_proxy_button),
            socks ? "Disable Proxy" : "Enable Proxy");
    }

    if (tproxy_item) {
        gtk_menu_item_set_label(GTK_MENU_ITEM(tproxy_item),
            tproxy ? "Disable TProxy" : "Enable TProxy");
    }
    if (controls_tproxy_button) {
        gtk_button_set_label(GTK_BUTTON(controls_tproxy_button),
            tproxy ? "Disable TProxy" : "Enable TProxy");
    }
    if (tun_item) {
        gtk_menu_item_set_label(GTK_MENU_ITEM(tun_item),
            tun ? "Disable TUN" : "Enable TUN");
    }
    if (controls_tun_button) {
        gtk_button_set_label(GTK_BUTTON(controls_tun_button),
            tun ? "Disable TUN" : "Enable TUN");
    }
}

static void on_proxy_toggle(GtkWidget *item, gpointer data) {
    (void)item; (void)data;
    if (service_active("proxy-suite-socks")) {
        if (service_active("proxy-suite-tproxy")) {
            run_privileged("stop", "proxy-suite-tproxy");
        }
        if (service_active("proxy-suite-tun")) {
            run_privileged("stop", "proxy-suite-tun");
        }
        run_privileged("stop", "proxy-suite-socks");
    } else {
        run_privileged("start", "proxy-suite-socks");
    }
    update_status();
}

static void on_tproxy_toggle(GtkWidget *item, gpointer data) {
    (void)item; (void)data;
    if (service_active("proxy-suite-tproxy")) {
        run_privileged("stop", "proxy-suite-tproxy");
    } else {
        run_privileged("start", "proxy-suite-tproxy");
    }
    update_status();
}

static void on_tun_toggle(GtkWidget *item, gpointer data) {
    (void)item; (void)data;
    if (service_active("proxy-suite-tun")) {
        run_privileged("stop", "proxy-suite-tun");
    } else {
        run_privileged("start", "proxy-suite-tun");
    }
    update_status();
}

static void on_restart(GtkWidget *item, gpointer data) {
    (void)item; (void)data;
    gboolean tun_was_active = service_active("proxy-suite-tun");

    if (run_privileged("restart", "proxy-suite-socks") && tun_was_active) {
        run_privileged("restart", "proxy-suite-tun");
    }

    update_status();
}

static void on_open_controls(GtkWidget *item, gpointer data) {
    (void)item; (void)data;
    if (!controls_window) {
        return;
    }
    update_status();
    gtk_widget_show_all(controls_window);
    gtk_window_present(GTK_WINDOW(controls_window));
}

static void on_quit(GtkWidget *item, gpointer data) {
    (void)item; (void)data;
    gtk_main_quit();
}

static gboolean on_timer(gpointer data) {
    (void)data;
    update_status();
    return TRUE;
}

static void build_controls_window(void) {
    controls_window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(controls_window), "Proxy Suite Controls");
    gtk_window_set_resizable(GTK_WINDOW(controls_window), FALSE);
    gtk_container_set_border_width(GTK_CONTAINER(controls_window), 8);
    g_signal_connect(controls_window, "delete-event", G_CALLBACK(on_controls_delete), NULL);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_container_add(GTK_CONTAINER(controls_window), box);

    controls_status_label = gtk_label_new("SOCKS Proxy: Unknown");
    gtk_label_set_xalign(GTK_LABEL(controls_status_label), 0.0f);
    gtk_box_pack_start(GTK_BOX(box), controls_status_label, FALSE, FALSE, 0);

    controls_proxy_button = gtk_button_new_with_label("Enable Proxy");
    g_signal_connect(controls_proxy_button, "clicked", G_CALLBACK(on_proxy_toggle), NULL);
    gtk_box_pack_start(GTK_BOX(box), controls_proxy_button, FALSE, FALSE, 0);

    if (service_exists("proxy-suite-tproxy")) {
        controls_tproxy_button = gtk_button_new_with_label("Enable TProxy");
        g_signal_connect(controls_tproxy_button, "clicked", G_CALLBACK(on_tproxy_toggle), NULL);
        gtk_box_pack_start(GTK_BOX(box), controls_tproxy_button, FALSE, FALSE, 0);
    }

    if (service_exists("proxy-suite-tun")) {
        controls_tun_button = gtk_button_new_with_label("Enable TUN");
        g_signal_connect(controls_tun_button, "clicked", G_CALLBACK(on_tun_toggle), NULL);
        gtk_box_pack_start(GTK_BOX(box), controls_tun_button, FALSE, FALSE, 0);
    }

    GtkWidget *restart_button = gtk_button_new_with_label("Restart Services");
    g_signal_connect(restart_button, "clicked", G_CALLBACK(on_restart), NULL);
    gtk_box_pack_start(GTK_BOX(box), restart_button, FALSE, FALSE, 0);

    GtkWidget *close_button = gtk_button_new_with_label("Close Window");
    g_signal_connect(close_button, "clicked", G_CALLBACK(on_close_controls), NULL);
    gtk_box_pack_start(GTK_BOX(box), close_button, FALSE, FALSE, 0);

    GtkWidget *quit_button = gtk_button_new_with_label("Exit Tray");
    g_signal_connect(quit_button, "clicked", G_CALLBACK(on_quit), NULL);
    gtk_box_pack_start(GTK_BOX(box), quit_button, FALSE, FALSE, 0);

    gtk_widget_show_all(controls_window);
    gtk_widget_hide(controls_window);
}

static void build_menu(void) {
    menu = gtk_menu_new();

    status_item = gtk_menu_item_new_with_label("SOCKS Proxy: Unknown");
    gtk_widget_set_sensitive(status_item, FALSE);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), status_item);

    gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());

    proxy_item = gtk_menu_item_new_with_label("Enable Proxy");
    g_signal_connect(proxy_item, "activate", G_CALLBACK(on_proxy_toggle), NULL);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), proxy_item);

    open_controls_item = gtk_menu_item_new_with_label("Open Controls");
    g_signal_connect(open_controls_item, "activate", G_CALLBACK(on_open_controls), NULL);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), open_controls_item);

    gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());

    if (service_exists("proxy-suite-tproxy")) {
        tproxy_item = gtk_menu_item_new_with_label("Enable TProxy");
        g_signal_connect(tproxy_item, "activate", G_CALLBACK(on_tproxy_toggle), NULL);
        gtk_menu_shell_append(GTK_MENU_SHELL(menu), tproxy_item);
    }

    if (service_exists("proxy-suite-tun")) {
        tun_item = gtk_menu_item_new_with_label("Enable TUN");
        g_signal_connect(tun_item, "activate", G_CALLBACK(on_tun_toggle), NULL);
        gtk_menu_shell_append(GTK_MENU_SHELL(menu), tun_item);
    }

    gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());

    GtkWidget *restart_item = gtk_menu_item_new_with_label("Restart Services");
    g_signal_connect(restart_item, "activate", G_CALLBACK(on_restart), NULL);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), restart_item);

    gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());

    GtkWidget *quit_item = gtk_menu_item_new_with_label("Exit");
    g_signal_connect(quit_item, "activate", G_CALLBACK(on_quit), NULL);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), quit_item);

    gtk_widget_show_all(menu);
}

int main(int argc, char *argv[]) {
    if (!gtk_init_check(&argc, &argv)) {
        fprintf(stderr, "proxy-suite-tray: failed to initialize GTK\n");
        return 1;
    }

    GError *bus_error = NULL;
    GDBusConnection *session_bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &bus_error);
    if (session_bus) {
        g_dbus_connection_add_filter(session_bus, on_session_bus_message, NULL, NULL);
        g_object_unref(session_bus);
    } else {
        fprintf(
            stderr,
            "proxy-suite-tray: warning: failed to monitor session bus: %s\n",
            bus_error ? bus_error->message : "unknown error"
        );
        g_clear_error(&bus_error);
    }

    indicator = app_indicator_new(
        "proxy-suite-tray",
        "network-vpn-disconnected",
        APP_INDICATOR_CATEGORY_SYSTEM_SERVICES
    );
    app_indicator_set_status(indicator, APP_INDICATOR_STATUS_ACTIVE);

    build_menu();
    build_controls_window();
    app_indicator_set_menu(indicator, GTK_MENU(menu));
    app_indicator_set_secondary_activate_target(indicator, open_controls_item);

    update_status();

    g_timeout_add_seconds(POLL_INTERVAL, on_timer, NULL);

    gtk_main();
    return 0;
}
