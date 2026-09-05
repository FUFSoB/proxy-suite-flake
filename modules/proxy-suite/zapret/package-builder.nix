# Builds derived zapret packages from the curated upstream package.
{
  lib,
  pkgs,
  zapretCfg,
  baseZapretPackage,
  effectiveHostlistRules,
  listGeneralFile,
  listExcludeFile,
  ipsetAllFile,
  ipsetExcludeFile,
  hostlistRuleSpec,
  patchConfigScript,
}:

let
  mkBypassScript =
    {
      filterMark ? null,
      tunInterfaces ? [ ],
      scope ? "global",
    }:
    pkgs.writeText "proxy-suite-zapret-bypass.sh" ''
      # Upstream presets can select iptables explicitly, in which case the nft
      # hook below is never called. Use upstream helpers for idempotent start
      # and stop, and distinct comments so each service owns its exemptions.
      zapret_custom_firewall() {
        local family rule_helper chain
        for family in 4 6; do
          if [ "$family" = 4 ]; then
            [ "''${DISABLE_IPV4:-0}" != 1 ] || continue
            rule_helper=ipt_add_del
          else
            [ "''${DISABLE_IPV6:-0}" != 1 ] || continue
            rule_helper=ipt6_add_del
          fi
          ${lib.optionalString (filterMark != null) ''
            for chain in POSTROUTING INPUT FORWARD; do
              "$rule_helper" "$1" "$chain" -t mangle -m mark ! --mark 0/${filterMark} -m comment --comment "proxy-suite ${scope} per-app-zapret bypass" -j RETURN
            done
          ''}
          ${lib.concatMapStrings (interface: ''
            "$rule_helper" "$1" POSTROUTING -t mangle -o ${lib.escapeShellArg interface} -m comment --comment "proxy-suite ${scope} TUN bypass" -j RETURN
            "$rule_helper" "$1" INPUT -t mangle -i ${lib.escapeShellArg interface} -m comment --comment "proxy-suite ${scope} TUN bypass" -j RETURN
            "$rule_helper" "$1" FORWARD -t mangle -i ${lib.escapeShellArg interface} -m comment --comment "proxy-suite ${scope} TUN bypass" -j RETURN
          '') tunInterfaces}
        done
        return 0
      }

      zapret_custom_firewall_nft() {
        ${lib.optionalString (filterMark != null) ''
          nft insert rule inet $ZAPRET_NFT_TABLE postrouting mark and ${filterMark} != 0 return comment '"proxy-suite per-app-zapret bypass"'
          nft insert rule inet $ZAPRET_NFT_TABLE postnat mark and ${filterMark} != 0 return comment '"proxy-suite per-app-zapret bypass"'
          nft insert rule inet $ZAPRET_NFT_TABLE prerouting mark and ${filterMark} != 0 return comment '"proxy-suite per-app-zapret bypass"'
          nft insert rule inet $ZAPRET_NFT_TABLE prenat mark and ${filterMark} != 0 return comment '"proxy-suite per-app-zapret bypass"'
        ''}
        # Desync packets must reach the physical network, never a TUN userspace
        # TCP stack: fake TLS payloads there can break the proxied handshake.
        ${lib.concatMapStrings (interface: ''
          nft insert rule inet $ZAPRET_NFT_TABLE postrouting oifname ${lib.escapeShellArg (builtins.toJSON interface)} return comment '"proxy-suite TUN bypass"'
          nft insert rule inet $ZAPRET_NFT_TABLE postnat oifname ${lib.escapeShellArg (builtins.toJSON interface)} return comment '"proxy-suite TUN bypass"'
          nft insert rule inet $ZAPRET_NFT_TABLE prerouting iifname ${lib.escapeShellArg (builtins.toJSON interface)} return comment '"proxy-suite TUN bypass"'
          nft insert rule inet $ZAPRET_NFT_TABLE prenat iifname ${lib.escapeShellArg (builtins.toJSON interface)} return comment '"proxy-suite TUN bypass"'
        '') tunInterfaces}
      }
    '';

  mkDerivedZapretPackage =
    {
      packageName,
      pidDir,
      configName ? zapretCfg.configName,
      gameFilter ? zapretCfg.gameFilter,
      forceDisableFilterMark ? false,
      filterMark ? null,
      qnum ? null,
      modeFilter ? null,
      desyncMark ? null,
      desyncMarkPostnat ? null,
      nftTable ? null,
      customScript ? null,
    }:
    pkgs.runCommand packageName
      {
        nativeBuildInputs = with pkgs; [
          coreutils
          gnused
          python3
        ];
      }
      ''
        set -euo pipefail

        mkdir -p "$out"
        cp -a ${baseZapretPackage}/. "$out/"
        chmod -R u+w "$out/opt/zapret" "$out/bin"

        find "$out/opt/zapret/configs" -type f -exec ${pkgs.gnused}/bin/sed -i \
          -e 's|${baseZapretPackage}/opt/zapret|'"$out"'/opt/zapret|g' \
          {} \;
        find "$out/opt/zapret/hostlists" -type f -exec ${pkgs.gnused}/bin/sed -i \
          -e 's|${baseZapretPackage}/opt/zapret|'"$out"'/opt/zapret|g' \
          {} \;

        requested_config=${lib.escapeShellArg configName}
        configs_dir="$out/opt/zapret/configs"
        selected_config="$configs_dir/$requested_config"

        config_name_key() {
          printf '%s' "$1" | tr -d '[:space:]'
        }

        if [ ! -f "$selected_config" ]; then
          requested_key=$(config_name_key "$requested_config")
          matched_config=""

          for candidate in "$configs_dir"/*; do
            [ -f "$candidate" ] || continue
            candidate_name="''${candidate##*/}"

            if [ "$(config_name_key "$candidate_name")" = "$requested_key" ]; then
              if [ -n "$matched_config" ]; then
                echo "proxy-suite: zapret config '$requested_config' is ambiguous after whitespace normalization" >&2
                echo "proxy-suite: matched '$matched_config' and '$candidate'" >&2
                exit 1
              fi
              matched_config="$candidate"
            fi
          done

          if [ -n "$matched_config" ]; then
            selected_config="$matched_config"
          fi
        fi

        if [ -f "$selected_config" ]; then
          cp "$selected_config" "$out/opt/zapret/config"
        else
          echo "proxy-suite: zapret config '$requested_config' not found in curated package" >&2
          ls -la "$out/opt/zapret/configs" >&2 || true
          exit 1
        fi

        ${pkgs.gnused}/bin/sed -i \
          -e 's|${baseZapretPackage}/opt/zapret|'"$out"'/opt/zapret|g' \
          "$out/opt/zapret/config"

        ${pkgs.gnused}/bin/sed -i \
          -e 's|^PIDDIR=.*$|PIDDIR=${pidDir}|' \
          "$out/opt/zapret/init.d/sysv/functions"

        append_list_file() {
          local target="$1"
          local extra_file="$2"
          local tmp="$out/opt/zapret/hostlists/$target.tmp"
          cat "$out/opt/zapret/hostlists/$target" > "$tmp"
          ${pkgs.gnused}/bin/sed -i -e '$a\' "$tmp"
          cat "$extra_file" >> "$tmp"
          mv "$tmp" "$out/opt/zapret/hostlists/$target"
        }

        set_config_var() {
          local key="$1"
          local value="$2"
          if grep -Eq "^[#[:space:]]*$key=" "$out/opt/zapret/config"; then
            ${pkgs.gnused}/bin/sed -Ei "s|^[#[:space:]]*$key=.*$|$key=$value|" "$out/opt/zapret/config"
          else
            printf '\n%s=%s\n' "$key" "$value" >> "$out/opt/zapret/config"
          fi
        }

        ${lib.concatMapStrings
          (
            { name, file }:
            lib.optionalString (file != null) ''
              append_list_file ${name} ${file}
            ''
          )
          [
            {
              name = "list-general-user.txt";
              file = listGeneralFile;
            }
            {
              name = "list-exclude-user.txt";
              file = listExcludeFile;
            }
            {
              name = "ipset-all.txt";
              file = ipsetAllFile;
            }
            {
              name = "ipset-exclude-user.txt";
              file = ipsetExcludeFile;
            }
          ]
        }

        rm -f "$out/opt/zapret/hostlists/.game_filter.enabled"
        ${lib.optionalString (gameFilter != "null") ''
          echo "${gameFilter}" > "$out/opt/zapret/hostlists/.game_filter.enabled"
        ''}

        ${lib.concatMapStrings (
          rule:
          let
            domainsFile = pkgs.writeText "proxy-suite-zapret-hostlist-${rule.name}.txt" (
              lib.concatStringsSep "\n" (lib.unique rule.domains) + "\n"
            );
            ipsetFile = pkgs.writeText "proxy-suite-zapret-ipset-${rule.name}.txt" (
              lib.concatStringsSep "\n" (lib.unique rule.ips) + "\n"
            );
          in
          lib.optionalString (rule.domains != [ ]) ''
            cp ${domainsFile} "$out/opt/zapret/hostlists/list-${rule.name}.txt"
          ''
          + lib.optionalString (rule.ips != [ ]) ''
            cp ${ipsetFile} "$out/opt/zapret/hostlists/ipset-${rule.name}.txt"
          ''
        ) effectiveHostlistRules}

        ${patchConfigScript} --config "$out/opt/zapret/config" --spec ${hostlistRuleSpec}

        ${lib.optionalString forceDisableFilterMark ''
          set_config_var FILTER_MARK ""
        ''}
        ${lib.concatMapStrings
          (
            { var, value }:
            lib.optionalString (value != null) ''
              hex=$(printf '0x%x' ${toString value})
              set_config_var ${var} "$hex"
            ''
          )
          [
            {
              var = "FILTER_MARK";
              value = filterMark;
            }
            {
              var = "DESYNC_MARK";
              value = desyncMark;
            }
            {
              var = "DESYNC_MARK_POSTNAT";
              value = desyncMarkPostnat;
            }
          ]
        }
        ${lib.optionalString (qnum != null) ''
          set_config_var QNUM ${toString qnum}
        ''}
        ${lib.optionalString (modeFilter != null) ''
          set_config_var MODE_FILTER ${modeFilter}
        ''}
        ${lib.optionalString (nftTable != null) ''
          set_config_var ZAPRET_NFT_TABLE ${nftTable}
        ''}

        ${lib.optionalString (customScript != null) ''
          mkdir -p "$out/opt/zapret/init.d/sysv/custom.d"
          cp ${customScript} "$out/opt/zapret/init.d/sysv/custom.d/50-proxy-suite-custom.sh"
          chmod +x "$out/opt/zapret/init.d/sysv/custom.d/50-proxy-suite-custom.sh"
        ''}
      '';
in
{
  inherit
    mkDerivedZapretPackage
    mkBypassScript
    ;
}
