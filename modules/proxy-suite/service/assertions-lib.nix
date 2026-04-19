{ lib }:

rec {
  mkAssertion = assertion: message: { inherit assertion message; };

  requireEnabled =
    featureEnabled: dependencyEnabled: message:
    mkAssertion (!featureEnabled || dependencyEnabled) message;

  requireAvailable =
    featureUsed: dependencyEnabled: message:
    mkAssertion (!featureUsed || dependencyEnabled) message;

  uniqueValues =
    condition: values: message:
    mkAssertion (!condition || builtins.length values == builtins.length (lib.unique values)) message;

  notEqualWhen =
    condition: left: right: message:
    mkAssertion (!(condition && left == right)) message;

  forbiddenValues =
    condition: value: disallowed: message:
    mkAssertion (!(condition && builtins.elem value disallowed)) message;

  exactlyOneOf =
    condition: values: message:
    mkAssertion (
      !condition || builtins.length (builtins.filter (value: value != null) values) == 1
    ) message;
}
