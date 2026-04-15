#include <gtk/gtk.h>
#include <gio/gio.h>
#include <libayatana-appindicator/app-indicator.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef POLL_INTERVAL
#define POLL_INTERVAL 5
#endif
#ifndef PROXY_CTL_BIN
#define PROXY_CTL_BIN "/run/current-system/sw/bin/proxy-ctl"
#endif


static AppIndicator *indicator;
static GtkWidget *menu;
static GtkWidget *status_item;
static GtkWidget *traffic_status_item;
static GtkWidget *zapret_status_item;
static GtkWidget *proxy_item;
static GtkWidget *tproxy_item;
static GtkWidget *tun_item;
static GtkWidget *zapret_item;
static GtkWidget *open_controls_item;
static GtkWidget *controls_window;
static GtkWidget *controls_summary_label;
static GtkWidget *controls_core_status_label;
static GtkWidget *controls_traffic_status_label;
static GtkWidget *controls_zapret_status_label;
static GtkWidget *controls_proxy_button;
static GtkWidget *controls_tproxy_button;
static GtkWidget *controls_tun_button;
static GtkWidget *controls_zapret_button;

typedef struct {
    gboolean loaded;
    gboolean socks_available;
    gboolean tproxy_available;
    gboolean tun_available;
    gboolean zapret_available;
    gboolean subscription_update_available;
    gboolean socks;
    gboolean tproxy;
    gboolean tun;
    gboolean zapret;
} ServiceState;

static ServiceState initial_state;

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

static gboolean run_proxy_ctl1(const char *arg1) {
    gchar *argv[] = {
        (gchar *) PROXY_CTL_BIN,
        (gchar *) arg1,
        NULL
    };

    return command_succeeds(argv);
}

static gboolean run_proxy_ctl2(const char *arg1, const char *arg2) {
    gchar *argv[] = {
        (gchar *) PROXY_CTL_BIN,
        (gchar *) arg1,
        (gchar *) arg2,
        NULL
    };

    return command_succeeds(argv);
}

static gboolean parse_proxy_ctl_bool(const char *value) {
    return value && strcmp(value, "true") == 0;
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

static ServiceState get_service_state(void) {
    ServiceState state = { 0 };
    gchar *stdout_text = NULL;
    gchar *argv[] = {
        (gchar *) PROXY_CTL_BIN,
        (gchar *) "status",
        (gchar *) "--tray",
        NULL
    };

    if (!command_stdout(argv, &stdout_text)) {
        return state;
    }

    state.loaded = TRUE;

    gchar **lines = g_strsplit(stdout_text, "\n", -1);
    for (gchar **line = lines; line && *line; ++line) {
        if ((*line)[0] == '\0') {
            continue;
        }

        gchar **parts = g_strsplit(*line, "=", 2);
        if (!parts[0] || !parts[1]) {
            g_strfreev(parts);
            continue;
        }

        if (strcmp(parts[0], "socks_available") == 0) {
            state.socks_available = parse_proxy_ctl_bool(parts[1]);
        } else if (strcmp(parts[0], "socks_active") == 0) {
            state.socks = parse_proxy_ctl_bool(parts[1]);
        } else if (strcmp(parts[0], "tproxy_available") == 0) {
            state.tproxy_available = parse_proxy_ctl_bool(parts[1]);
        } else if (strcmp(parts[0], "tproxy_active") == 0) {
            state.tproxy = parse_proxy_ctl_bool(parts[1]);
        } else if (strcmp(parts[0], "tun_available") == 0) {
            state.tun_available = parse_proxy_ctl_bool(parts[1]);
        } else if (strcmp(parts[0], "tun_active") == 0) {
            state.tun = parse_proxy_ctl_bool(parts[1]);
        } else if (strcmp(parts[0], "zapret_available") == 0) {
            state.zapret_available = parse_proxy_ctl_bool(parts[1]);
        } else if (strcmp(parts[0], "zapret_active") == 0) {
            state.zapret = parse_proxy_ctl_bool(parts[1]);
        } else if (strcmp(parts[0], "subscription_update_available") == 0) {
            state.subscription_update_available = parse_proxy_ctl_bool(parts[1]);
        }

        g_strfreev(parts);
    }

    g_strfreev(lines);
    g_free(stdout_text);

    return state;
}

static const char *traffic_mode_label(const ServiceState *state) {
    if (state->tun) {
        return "TUN tunnel enabled";
    }
    if (state->tproxy) {
        return "TProxy interception enabled";
    }
    return "System-wide routing disabled";
}

static const char *indicator_label_text(const ServiceState *state) {
    if (state->socks && (state->tproxy || state->tun) && state->zapret) {
        return "Proxy + traffic + zapret";
    }
    if (state->socks && (state->tproxy || state->tun)) {
        return "Proxy + traffic";
    }
    if (state->socks && state->zapret) {
        return "Proxy + zapret";
    }
    if (state->socks) {
        return "Proxy only";
    }
    if (state->zapret) {
        return "Zapret only";
    }
    return "Inactive";
}

static void update_status(void) {
    ServiceState state = get_service_state();
    /* Gold: TUN/TProxy active (highest priority) */
    static const char *const tunnel_icons[] = {
        "proxy-suite-tunnel",
        "proxy-suite-tunnel-symbolic",
        "network-vpn",
        "network-vpn-symbolic"
    };
    /* Green: proxy + zapret, no tunnel */
    static const char *const active_icons[] = {
        "proxy-suite-active",
        "proxy-suite-active-symbolic",
        "network-vpn",
        "network-vpn-symbolic"
    };
    /* Orange: proxy only */
    static const char *const proxy_icons[] = {
        "proxy-suite-proxy",
        "proxy-suite-proxy-symbolic",
        "network-vpn-acquiring",
        "network-vpn-acquiring-symbolic",
        "network-vpn",
        "network-vpn-symbolic"
    };
    /* Blue: zapret only */
    static const char *const zapret_icons[] = {
        "proxy-suite-zapret",
        "proxy-suite-zapret-symbolic",
        "network-vpn-acquiring",
        "network-vpn-acquiring-symbolic",
        "network-vpn",
        "network-vpn-symbolic"
    };
    /* Red: everything disabled */
    static const char *const disabled_icons[] = {
        "proxy-suite-disabled",
        "proxy-suite-disabled-symbolic",
        "network-vpn-disconnected",
        "network-offline",
        "network-error",
        "dialog-error",
        "network-vpn-disconnected-symbolic",
        "network-offline-symbolic",
        "network-error-symbolic",
        "dialog-error-symbolic"
    };

    if (!state.loaded) {
        app_indicator_set_icon(
            indicator,
            pick_icon_name(disabled_icons, G_N_ELEMENTS(disabled_icons), "network-vpn-disconnected")
        );
        app_indicator_set_label(indicator, "Status unavailable", "");

        if (status_item) {
            gtk_menu_item_set_label(GTK_MENU_ITEM(status_item), "[Status] proxy-ctl status unavailable");
        }
        if (traffic_status_item) {
            gtk_menu_item_set_label(GTK_MENU_ITEM(traffic_status_item), "[Traffic] Mode: Unknown");
        }
        if (zapret_status_item) {
            gtk_menu_item_set_label(GTK_MENU_ITEM(zapret_status_item), "[Zapret] zapret-discord-youtube: Unknown");
        }
        if (controls_summary_label) {
            gtk_label_set_text(GTK_LABEL(controls_summary_label), "[Status] proxy-ctl status unavailable");
        }
        if (controls_core_status_label) {
            gtk_label_set_text(GTK_LABEL(controls_core_status_label), "[Core] SOCKS proxy: Unknown");
        }
        if (controls_traffic_status_label) {
            gtk_label_set_text(GTK_LABEL(controls_traffic_status_label), "[Traffic] Mode: Unknown");
        }
        if (controls_zapret_status_label) {
            gtk_label_set_text(GTK_LABEL(controls_zapret_status_label), "[Zapret] zapret-discord-youtube: Unknown");
        }
        return;
    }

    const char *traffic = traffic_mode_label(&state);
    const char *summary = indicator_label_text(&state);
    const char *zapret = state.zapret ? "Active" : "Stopped";
    gchar *summary_text = g_strdup_printf(
        "[Status] %s | Traffic: %s | Zapret: %s",
        state.socks ? "Proxy ready" : "Proxy down",
        traffic,
        zapret
    );
    gchar *core_text = g_strdup_printf(
        "[Core] SOCKS proxy: %s",
        state.socks ? "Running" : "Stopped"
    );
    gchar *traffic_text = g_strdup_printf("[Traffic] Mode: %s", traffic);
    gchar *zapret_text = g_strdup_printf(
        "[Zapret] zapret-discord-youtube: %s",
        zapret
    );

    if (state.tproxy || state.tun) {
        app_indicator_set_icon(
            indicator,
            pick_icon_name(tunnel_icons, G_N_ELEMENTS(tunnel_icons), "network-vpn")
        );
    } else if (state.socks && state.zapret) {
        app_indicator_set_icon(
            indicator,
            pick_icon_name(active_icons, G_N_ELEMENTS(active_icons), "network-vpn")
        );
    } else if (state.socks) {
        app_indicator_set_icon(
            indicator,
            pick_icon_name(proxy_icons, G_N_ELEMENTS(proxy_icons), "network-vpn-acquiring")
        );
    } else if (state.zapret) {
        app_indicator_set_icon(
            indicator,
            pick_icon_name(zapret_icons, G_N_ELEMENTS(zapret_icons), "network-vpn-acquiring")
        );
    } else {
        app_indicator_set_icon(
            indicator,
            pick_icon_name(disabled_icons, G_N_ELEMENTS(disabled_icons), "network-vpn-disconnected")
        );
    }
    app_indicator_set_label(indicator, summary, "");

    if (status_item) {
        gtk_menu_item_set_label(GTK_MENU_ITEM(status_item), summary_text);
    }
    if (traffic_status_item) {
        gtk_menu_item_set_label(GTK_MENU_ITEM(traffic_status_item), traffic_text);
    }
    if (zapret_status_item) {
        gtk_menu_item_set_label(GTK_MENU_ITEM(zapret_status_item), zapret_text);
    }
    if (controls_summary_label) {
        gtk_label_set_text(GTK_LABEL(controls_summary_label), summary_text);
    }
    if (controls_core_status_label) {
        gtk_label_set_text(GTK_LABEL(controls_core_status_label), core_text);
    }
    if (controls_traffic_status_label) {
        gtk_label_set_text(GTK_LABEL(controls_traffic_status_label), traffic_text);
    }
    if (controls_zapret_status_label) {
        gtk_label_set_text(GTK_LABEL(controls_zapret_status_label), zapret_text);
    }
    if (proxy_item) {
        gtk_menu_item_set_label(GTK_MENU_ITEM(proxy_item),
            state.socks ? "[Core] Stop SOCKS Proxy" : "[Core] Start SOCKS Proxy");
    }
    if (controls_proxy_button) {
        gtk_button_set_label(GTK_BUTTON(controls_proxy_button),
            state.socks ? "Stop SOCKS Proxy" : "Start SOCKS Proxy");
    }

    if (tproxy_item) {
        gtk_menu_item_set_label(GTK_MENU_ITEM(tproxy_item),
            state.tproxy ? "[Traffic] Stop TProxy Mode" : "[Traffic] Start TProxy Mode");
    }
    if (controls_tproxy_button) {
        gtk_button_set_label(GTK_BUTTON(controls_tproxy_button),
            state.tproxy ? "Stop TProxy Mode" : "Start TProxy Mode");
    }
    if (tun_item) {
        gtk_menu_item_set_label(GTK_MENU_ITEM(tun_item),
            state.tun ? "[Traffic] Stop TUN Mode" : "[Traffic] Start TUN Mode");
    }
    if (controls_tun_button) {
        gtk_button_set_label(GTK_BUTTON(controls_tun_button),
            state.tun ? "Stop TUN Mode" : "Start TUN Mode");
    }
    if (zapret_item) {
        gtk_menu_item_set_label(
            GTK_MENU_ITEM(zapret_item),
            state.zapret ? "[Zapret] Stop zapret-discord-youtube" : "[Zapret] Start zapret-discord-youtube"
        );
    }
    if (controls_zapret_button) {
        gtk_button_set_label(
            GTK_BUTTON(controls_zapret_button),
            state.zapret ? "Stop zapret-discord-youtube" : "Start zapret-discord-youtube"
        );
    }

    g_free(summary_text);
    g_free(core_text);
    g_free(traffic_text);
    g_free(zapret_text);
}

static void on_proxy_toggle(GtkWidget *item, gpointer data) {
    (void)item; (void)data;
    ServiceState state = get_service_state();
    if (state.socks) {
        run_proxy_ctl2("proxy", "off");
    } else {
        run_proxy_ctl2("proxy", "on");
    }
    update_status();
}

static void on_tproxy_toggle(GtkWidget *item, gpointer data) {
    (void)item; (void)data;
    ServiceState state = get_service_state();
    if (state.tproxy) {
        run_proxy_ctl2("tproxy", "off");
    } else {
        run_proxy_ctl2("tproxy", "on");
    }
    update_status();
}

static void on_tun_toggle(GtkWidget *item, gpointer data) {
    (void)item; (void)data;
    ServiceState state = get_service_state();
    if (state.tun) {
        run_proxy_ctl2("tun", "off");
    } else {
        run_proxy_ctl2("tun", "on");
    }
    update_status();
}

static void on_zapret_toggle(GtkWidget *item, gpointer data) {
    (void)item; (void)data;
    ServiceState state = get_service_state();
    if (state.zapret) {
        run_proxy_ctl2("zapret", "off");
    } else {
        run_proxy_ctl2("zapret", "on");
    }
    update_status();
}

static void on_restart(GtkWidget *item, gpointer data) {
    (void)item; (void)data;
    run_proxy_ctl1("restart");
    update_status();
}

static void on_subscription_update(GtkWidget *item, gpointer data) {
    (void)item; (void)data;
    run_proxy_ctl2("subscription", "update");
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

    controls_summary_label = gtk_label_new("[Status] Loading service state...");
    gtk_label_set_xalign(GTK_LABEL(controls_summary_label), 0.0f);
    gtk_box_pack_start(GTK_BOX(box), controls_summary_label, FALSE, FALSE, 0);

    GtkWidget *core_frame = gtk_frame_new("[Core] Proxy");
    GtkWidget *core_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_container_set_border_width(GTK_CONTAINER(core_box), 6);
    gtk_container_add(GTK_CONTAINER(core_frame), core_box);
    gtk_box_pack_start(GTK_BOX(box), core_frame, FALSE, FALSE, 0);

    controls_core_status_label = gtk_label_new("[Core] SOCKS proxy: Unknown");
    gtk_label_set_xalign(GTK_LABEL(controls_core_status_label), 0.0f);
    gtk_box_pack_start(GTK_BOX(core_box), controls_core_status_label, FALSE, FALSE, 0);

    controls_proxy_button = gtk_button_new_with_label("Start SOCKS Proxy");
    g_signal_connect(controls_proxy_button, "clicked", G_CALLBACK(on_proxy_toggle), NULL);
    gtk_box_pack_start(GTK_BOX(core_box), controls_proxy_button, FALSE, FALSE, 0);

    GtkWidget *traffic_frame = gtk_frame_new("[Traffic] System-wide traffic mode");
    GtkWidget *traffic_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_container_set_border_width(GTK_CONTAINER(traffic_box), 6);
    gtk_container_add(GTK_CONTAINER(traffic_frame), traffic_box);
    gtk_box_pack_start(GTK_BOX(box), traffic_frame, FALSE, FALSE, 0);

    controls_traffic_status_label = gtk_label_new("[Traffic] Mode: Unknown");
    gtk_label_set_xalign(GTK_LABEL(controls_traffic_status_label), 0.0f);
    gtk_box_pack_start(GTK_BOX(traffic_box), controls_traffic_status_label, FALSE, FALSE, 0);

    if (initial_state.tproxy_available) {
        controls_tproxy_button = gtk_button_new_with_label("Start TProxy Mode");
        g_signal_connect(controls_tproxy_button, "clicked", G_CALLBACK(on_tproxy_toggle), NULL);
        gtk_box_pack_start(GTK_BOX(traffic_box), controls_tproxy_button, FALSE, FALSE, 0);
    }

    if (initial_state.tun_available) {
        controls_tun_button = gtk_button_new_with_label("Start TUN Mode");
        g_signal_connect(controls_tun_button, "clicked", G_CALLBACK(on_tun_toggle), NULL);
        gtk_box_pack_start(GTK_BOX(traffic_box), controls_tun_button, FALSE, FALSE, 0);
    }

    if (initial_state.zapret_available) {
        GtkWidget *zapret_frame = gtk_frame_new("[Zapret] DPI bypass");
        GtkWidget *zapret_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
        gtk_container_set_border_width(GTK_CONTAINER(zapret_box), 6);
        gtk_container_add(GTK_CONTAINER(zapret_frame), zapret_box);
        gtk_box_pack_start(GTK_BOX(box), zapret_frame, FALSE, FALSE, 0);

        controls_zapret_status_label = gtk_label_new("[Zapret] zapret-discord-youtube: Unknown");
        gtk_label_set_xalign(GTK_LABEL(controls_zapret_status_label), 0.0f);
        gtk_box_pack_start(GTK_BOX(zapret_box), controls_zapret_status_label, FALSE, FALSE, 0);

        controls_zapret_button = gtk_button_new_with_label("Start zapret-discord-youtube");
        g_signal_connect(controls_zapret_button, "clicked", G_CALLBACK(on_zapret_toggle), NULL);
        gtk_box_pack_start(GTK_BOX(zapret_box), controls_zapret_button, FALSE, FALSE, 0);
    }

    GtkWidget *tools_frame = gtk_frame_new("[Tools] Maintenance");
    GtkWidget *tools_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_container_set_border_width(GTK_CONTAINER(tools_box), 6);
    gtk_container_add(GTK_CONTAINER(tools_frame), tools_box);
    gtk_box_pack_start(GTK_BOX(box), tools_frame, FALSE, FALSE, 0);

    if (initial_state.subscription_update_available) {
        GtkWidget *sub_update_button = gtk_button_new_with_label("Update Subscriptions");
        g_signal_connect(sub_update_button, "clicked", G_CALLBACK(on_subscription_update), NULL);
        gtk_box_pack_start(GTK_BOX(tools_box), sub_update_button, FALSE, FALSE, 0);
    }

    GtkWidget *restart_button = gtk_button_new_with_label("Restart Active Services");
    g_signal_connect(restart_button, "clicked", G_CALLBACK(on_restart), NULL);
    gtk_box_pack_start(GTK_BOX(tools_box), restart_button, FALSE, FALSE, 0);

    GtkWidget *close_button = gtk_button_new_with_label("Close Window");
    g_signal_connect(close_button, "clicked", G_CALLBACK(on_close_controls), NULL);
    gtk_box_pack_start(GTK_BOX(tools_box), close_button, FALSE, FALSE, 0);

    GtkWidget *quit_button = gtk_button_new_with_label("Exit Tray");
    g_signal_connect(quit_button, "clicked", G_CALLBACK(on_quit), NULL);
    gtk_box_pack_start(GTK_BOX(tools_box), quit_button, FALSE, FALSE, 0);

    gtk_widget_show_all(controls_window);
    gtk_widget_hide(controls_window);
}

static void build_menu(void) {
    menu = gtk_menu_new();

    status_item = gtk_menu_item_new_with_label("[Status] Loading service state...");
    gtk_widget_set_sensitive(status_item, FALSE);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), status_item);

    traffic_status_item = gtk_menu_item_new_with_label("[Traffic] Mode: Unknown");
    gtk_widget_set_sensitive(traffic_status_item, FALSE);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), traffic_status_item);

    zapret_status_item = gtk_menu_item_new_with_label("[Zapret] zapret-discord-youtube: Unknown");
    gtk_widget_set_sensitive(zapret_status_item, FALSE);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), zapret_status_item);

    gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());

    proxy_item = gtk_menu_item_new_with_label("[Core] Start SOCKS Proxy");
    g_signal_connect(proxy_item, "activate", G_CALLBACK(on_proxy_toggle), NULL);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), proxy_item);

    open_controls_item = gtk_menu_item_new_with_label("Open Controls");
    g_signal_connect(open_controls_item, "activate", G_CALLBACK(on_open_controls), NULL);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), open_controls_item);

    gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());

    if (initial_state.tproxy_available) {
        tproxy_item = gtk_menu_item_new_with_label("[Traffic] Start TProxy Mode");
        g_signal_connect(tproxy_item, "activate", G_CALLBACK(on_tproxy_toggle), NULL);
        gtk_menu_shell_append(GTK_MENU_SHELL(menu), tproxy_item);
    }

    if (initial_state.tun_available) {
        tun_item = gtk_menu_item_new_with_label("[Traffic] Start TUN Mode");
        g_signal_connect(tun_item, "activate", G_CALLBACK(on_tun_toggle), NULL);
        gtk_menu_shell_append(GTK_MENU_SHELL(menu), tun_item);
    }

    if (initial_state.zapret_available) {
        gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());

        zapret_item = gtk_menu_item_new_with_label("[Zapret] Start zapret-discord-youtube");
        g_signal_connect(zapret_item, "activate", G_CALLBACK(on_zapret_toggle), NULL);
        gtk_menu_shell_append(GTK_MENU_SHELL(menu), zapret_item);
    }

    if (initial_state.subscription_update_available) {
        gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());

        GtkWidget *sub_update_item = gtk_menu_item_new_with_label("Update Subscriptions");
        g_signal_connect(sub_update_item, "activate", G_CALLBACK(on_subscription_update), NULL);
        gtk_menu_shell_append(GTK_MENU_SHELL(menu), sub_update_item);
    }

    gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());

    GtkWidget *restart_item = gtk_menu_item_new_with_label("[Tools] Restart Active Services");
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
        "proxy-suite-disabled",
        APP_INDICATOR_CATEGORY_SYSTEM_SERVICES
    );
    app_indicator_set_status(indicator, APP_INDICATOR_STATUS_ACTIVE);

    initial_state = get_service_state();
    build_menu();
    build_controls_window();
    app_indicator_set_menu(indicator, GTK_MENU(menu));
    app_indicator_set_secondary_activate_target(indicator, open_controls_item);

    update_status();

    g_timeout_add_seconds(POLL_INTERVAL, on_timer, NULL);

    gtk_main();
    return 0;
}
