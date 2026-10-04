var verb = action.lookup("verb");
if (typeof unit !== "string" || @verbs@.indexOf(verb) === -1) {
  return null;
}
var known = @units@.indexOf(unit) !== -1;
var templates = @templates@;
for (var i = 0; !known && i < templates.length; i++) {
  var template = templates[i];
  if (unit.indexOf(template) !== 0) {
    continue;
  }
  var instance = unit.slice(template.length).replace(/\.service$/, "");
  if (!/^[A-Za-z0-9:_.\\-]+$/.test(instance) || unit !== template + instance + ".service") {
    continue;
  }
  // Per-app marking follows one user's apps: only that user's own instance.
  if (/-user@$/.test(template)) {
    try {
      var uid = polkit.spawn(["@coreutils@/bin/id", "-u", "--", subject.user]).trim();
    } catch (error) {
      return null;
    }
    if (instance !== uid) {
      return null;
    }
  }
  known = true;
}
if (!known) {
  return null;
}

var scopeByUnitPrefix = @scopeByUnitPrefix@;
var scope = "services";
for (var prefix in scopeByUnitPrefix) {
  if (unit.indexOf(prefix) === 0) {
    scope = scopeByUnitPrefix[prefix];
    break;
  }
}
// Any of the subject's groups that holds the scope.
var groupScopes = @groupScopes@;
for (var group in groupScopes) {
  if (groupScopes[group].indexOf(scope) !== -1 && subject.isInGroup(group)) {
    return polkit.Result.YES;
  }
}
