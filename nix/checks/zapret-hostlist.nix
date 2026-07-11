{
  pkgs,
  zapretSyncBase,
  zapretSyncExtraListsBase,
  zapretSyncNoExtraListsBase,
  zapretSpacedConfigAliasBase,
  zapretUnspacedConfigAliasBase,
  zapretHostlistBase,
}:

{
  rules = pkgs.runCommand "proxy-suite-zapret-hostlist-rules-check" { } ''
    grep -F -- '--hostlist="${zapretSyncExtraListsBase}/hostlists/list-twitter.txt"' "${zapretSyncExtraListsBase}/config"
    grep -F -- '--hostlist="${zapretSyncExtraListsBase}/hostlists/list-instagram.txt"' "${zapretSyncExtraListsBase}/config"
    grep -F -- '--hostlist="${zapretSyncExtraListsBase}/hostlists/list-soundcloud.txt"' "${zapretSyncExtraListsBase}/config"
    ! grep -F -- '--hostlist="${zapretSyncBase}/hostlists/list-twitter.txt"' "${zapretSyncBase}/config"
    ! grep -F -- '--hostlist="${zapretSyncBase}/hostlists/list-instagram.txt"' "${zapretSyncBase}/config"
    ! grep -F -- '--hostlist="${zapretSyncBase}/hostlists/list-soundcloud.txt"' "${zapretSyncBase}/config"
    test -f "${zapretSpacedConfigAliasBase}/config"
    test -f "${zapretUnspacedConfigAliasBase}/config"
    ! grep -F -- '--hostlist="${zapretSyncNoExtraListsBase}/hostlists/list-twitter.txt"' "${zapretSyncNoExtraListsBase}/config"
    ! grep -F -- '--hostlist="${zapretSyncNoExtraListsBase}/hostlists/list-instagram.txt"' "${zapretSyncNoExtraListsBase}/config"
    ! grep -F -- '--hostlist="${zapretSyncNoExtraListsBase}/hostlists/list-soundcloud.txt"' "${zapretSyncNoExtraListsBase}/config"
    grep -F 'googlevideo.com' "${zapretHostlistBase}/hostlists/list-googlevideo.txt"
    grep -F 'example.de' "${zapretHostlistBase}/hostlists/list-example.txt"
    grep -F -- '--hostlist="${zapretHostlistBase}/hostlists/list-googlevideo.txt"' "${zapretHostlistBase}/config"
    grep -F -- '--hostlist="${zapretHostlistBase}/hostlists/list-example.txt"' "${zapretHostlistBase}/config"
    grep -F -- '--filter-tcp=443 --dpi-desync=fake,multisplit --hostlist="${zapretHostlistBase}/hostlists/list-example.txt" --hostlist-exclude="${zapretHostlistBase}/hostlists/list-exclude.txt" --hostlist-exclude="${zapretHostlistBase}/hostlists/list-exclude-user.txt" --ipset-exclude="${zapretHostlistBase}/hostlists/ipset-exclude.txt" --ipset-exclude="${zapretHostlistBase}/hostlists/ipset-exclude-user.txt" --new' "${zapretHostlistBase}/config"
    grep -F 'youtube.com' "${zapretHostlistBase}/hostlists/list-google-general.txt"
    grep -F 'googlevideo.com' "${zapretHostlistBase}/hostlists/list-google-general.txt"
    grep -F 'discord.com' "${zapretHostlistBase}/hostlists/list-general-alt12.txt"
    grep -F 'discord.gg' "${zapretHostlistBase}/hostlists/list-general-alt12.txt"
    grep -F 'cloudflare-ech.com' "${zapretHostlistBase}/hostlists/list-general-alt12.txt"
    grep -F 'cloudfront.net' "${zapretHostlistBase}/hostlists/list-general-alt12.txt"
    grep -F '7tv.app' "${zapretHostlistBase}/hostlists/list-general-alt12.txt"
    cmp "${zapretHostlistBase}/hostlists/list-google-general.txt" "${zapretHostlistBase}/hostlists/list-youtube-alias.txt"
    cmp "${zapretHostlistBase}/hostlists/list-general-alt12.txt" "${zapretHostlistBase}/hostlists/list-discord-alias.txt"
    grep -F '1.1.1.0/24' "${zapretHostlistBase}/hostlists/ipset-upstream-ips.txt"
    grep -F '203.0.113.0/24' "${zapretHostlistBase}/hostlists/ipset-explicit-ips.txt"
    grep -F -- '--hostlist="${zapretHostlistBase}/hostlists/list-google-general.txt"' "${zapretHostlistBase}/config"
    grep -F -- '--dpi-desync=multisplit --dpi-desync-split-seqovl=681' "${zapretHostlistBase}/config"
    grep -F -- '--ipset="${zapretHostlistBase}/hostlists/ipset-upstream-ips.txt"' "${zapretHostlistBase}/config"
    grep -F -- '--ipset="${zapretHostlistBase}/hostlists/ipset-explicit-ips.txt"' "${zapretHostlistBase}/config"
    google_rule_line=$(grep -nF -- '--hostlist="${zapretHostlistBase}/hostlists/list-google-general.txt"' "${zapretHostlistBase}/config" | head -n1 | cut -d: -f1)
    default_google_rule_line=$(grep -nF -- '--hostlist="${zapretHostlistBase}/hostlists/list-google.txt"' "${zapretHostlistBase}/config" | head -n1 | cut -d: -f1)
    general_rule_line=$(grep -nF -- '--hostlist="${zapretHostlistBase}/hostlists/list-general-alt12.txt"' "${zapretHostlistBase}/config" | head -n1 | cut -d: -f1)
    default_general_rule_line=$(grep -nF -- '--hostlist="${zapretHostlistBase}/hostlists/list-general.txt"' "${zapretHostlistBase}/config" | head -n1 | cut -d: -f1)
    discord_voice_rule_line=$(grep -nF -- '--filter-l7=discord,stun' "${zapretHostlistBase}/config" | grep -F -- '--dpi-desync-repeats=3' | head -n1 | cut -d: -f1)
    default_voice_rule_line=$(grep -nF -- '--filter-l7=discord,stun' "${zapretHostlistBase}/config" | grep -F -- '--dpi-desync-repeats=6' | head -n1 | cut -d: -f1)
    test "$google_rule_line" -lt "$default_google_rule_line"
    test "$general_rule_line" -lt "$default_general_rule_line"
    test "$discord_voice_rule_line" -lt "$default_voice_rule_line"
    touch "$out"
  '';
}
