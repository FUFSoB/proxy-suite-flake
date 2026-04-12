#include <gtk/gtk.h>
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
static GtkWidget *tproxy_item;
static GtkWidget *tun_item;

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

static void update_status(void) {
    gboolean socks = service_active("proxy-suite-socks");
    gboolean tproxy = service_active("proxy-suite-tproxy");
    gboolean tun = service_active("proxy-suite-tun");

    if (socks) {
        if (tproxy || tun) {
            app_indicator_set_icon(indicator, "network-vpn");
        } else {
            app_indicator_set_icon(indicator, "network-vpn-acquiring");
        }
    } else {
        app_indicator_set_icon(indicator, "network-vpn-disconnected");
    }

    gtk_menu_item_set_label(GTK_MENU_ITEM(status_item),
        socks ? "SOCKS Proxy: Running" : "SOCKS Proxy: Stopped");

    if (tproxy_item) {
        gtk_menu_item_set_label(GTK_MENU_ITEM(tproxy_item),
            tproxy ? "Disable TProxy" : "Enable TProxy");
    }
    if (tun_item) {
        gtk_menu_item_set_label(GTK_MENU_ITEM(tun_item),
            tun ? "Disable TUN" : "Enable TUN");
    }
}

static void on_tproxy_toggle(GtkMenuItem *item, gpointer data) {
    (void)item; (void)data;
    if (service_active("proxy-suite-tproxy")) {
        run_privileged("stop", "proxy-suite-tproxy");
    } else {
        run_privileged("start", "proxy-suite-tproxy");
    }
    update_status();
}

static void on_tun_toggle(GtkMenuItem *item, gpointer data) {
    (void)item; (void)data;
    if (service_active("proxy-suite-tun")) {
        run_privileged("stop", "proxy-suite-tun");
    } else {
        run_privileged("start", "proxy-suite-tun");
    }
    update_status();
}

static void on_restart(GtkMenuItem *item, gpointer data) {
    (void)item; (void)data;
    gboolean tun_was_active = service_active("proxy-suite-tun");

    if (run_privileged("restart", "proxy-suite-socks") && tun_was_active) {
        run_privileged("restart", "proxy-suite-tun");
    }

    update_status();
}

static void on_quit(GtkMenuItem *item, gpointer data) {
    (void)item; (void)data;
    gtk_main_quit();
}

static gboolean on_timer(gpointer data) {
    (void)data;
    update_status();
    return TRUE;
}

static void build_menu(void) {
    menu = gtk_menu_new();

    status_item = gtk_menu_item_new_with_label("SOCKS Proxy: Unknown");
    gtk_widget_set_sensitive(status_item, FALSE);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), status_item);

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

    indicator = app_indicator_new(
        "proxy-suite-tray",
        "network-vpn-disconnected",
        APP_INDICATOR_CATEGORY_SYSTEM_SERVICES
    );
    app_indicator_set_status(indicator, APP_INDICATOR_STATUS_ACTIVE);

    build_menu();
    app_indicator_set_menu(indicator, GTK_MENU(menu));

    update_status();

    g_timeout_add_seconds(POLL_INTERVAL, on_timer, NULL);

    gtk_main();
    return 0;
}
