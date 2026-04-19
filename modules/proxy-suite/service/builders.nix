{
  lib,
  pkgs,
}:

let
  mkOptionalTopLevel =
    {
      description,
      after ? [ ],
      wantedBy ? [ ],
      wants ? [ ],
      requires ? [ ],
      conflicts ? [ ],
      preStart ? null,
    }:
    {
      inherit description after wantedBy wants requires conflicts;
    }
    // lib.optionalAttrs (preStart != null) { inherit preStart; };
in
rec {
  mkNamedUnits =
    entries:
    lib.listToAttrs (
      map (entry: lib.nameValuePair entry.name entry.value) (builtins.filter (entry: entry.enable) entries)
    );

  mkRestartingService =
    {
      description,
      execStart,
      runtimeDirectory,
      stateDirectory ? null,
      after ? [ ],
      wantedBy ? [ ],
      wants ? [ ],
      requires ? [ ],
      conflicts ? [ ],
      execStartPost ? null,
      execStopPost ? null,
      extraServiceConfig ? { },
      preStart ? null,
    }:
    (mkOptionalTopLevel {
      inherit
        description
        after
        wantedBy
        wants
        requires
        conflicts
        preStart
        ;
    })
    // {
      serviceConfig =
        {
          ExecStart = execStart;
          Restart = "on-failure";
          RestartSec = 5;
          RuntimeDirectory = runtimeDirectory;
        }
        // lib.optionalAttrs (stateDirectory != null) { StateDirectory = stateDirectory; }
        // lib.optionalAttrs (execStartPost != null) { ExecStartPost = execStartPost; }
        // lib.optionalAttrs (execStopPost != null) { ExecStopPost = execStopPost; }
        // extraServiceConfig;
    };

  mkOneshotService =
    {
      description,
      execStart,
      execStop ? null,
      execStartPre ? null,
      execStartPost ? null,
      execStopPost ? null,
      runtimeDirectory ? null,
      stateDirectory ? null,
      after ? [ ],
      wantedBy ? [ ],
      wants ? [ ],
      requires ? [ ],
      conflicts ? [ ],
      extraServiceConfig ? { },
      preStart ? null,
    }:
    (mkOptionalTopLevel {
      inherit
        description
        after
        wantedBy
        wants
        requires
        conflicts
        preStart
        ;
    })
    // {
      serviceConfig =
        {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = execStart;
        }
        // lib.optionalAttrs (execStop != null) { ExecStop = execStop; }
        // lib.optionalAttrs (execStartPre != null) { ExecStartPre = execStartPre; }
        // lib.optionalAttrs (execStartPost != null) { ExecStartPost = execStartPost; }
        // lib.optionalAttrs (execStopPost != null) { ExecStopPost = execStopPost; }
        // lib.optionalAttrs (runtimeDirectory != null) { RuntimeDirectory = runtimeDirectory; }
        // lib.optionalAttrs (stateDirectory != null) { StateDirectory = stateDirectory; }
        // extraServiceConfig;
    };

  mkUserRuleService =
    {
      description,
      backendService,
      execStart,
      execStop,
    }:
    mkOneshotService {
      inherit description execStart execStop;
      requires = [ "${backendService}.service" ];
      after = [ "${backendService}.service" ];
    };

  mkAnchorService =
    sliceName: description:
    mkOneshotService {
      inherit description;
      execStart = "${pkgs.coreutils}/bin/true";
      execStop = "${pkgs.coreutils}/bin/true";
      extraServiceConfig.Slice = sliceName;
    };
}
