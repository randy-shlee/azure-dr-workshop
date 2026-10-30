const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const formPath = process.argv[2] || path.join(__dirname, '../uiFormDefinition.json');
const form = JSON.parse(fs.readFileSync(formPath, 'utf8'));
const elements = Object.fromEntries(form.view.properties.steps.map(step => [
  step.name, Object.fromEntries(step.elements.map(element => [element.name, element]))
]));
const login = elements.postgres.administratorLogin;
const password = elements.postgres.administratorPassword;
let state;
const functions = {
  steps: name => state[name],
  utcNow: () => '2026-10-30T12:00:00.000Z',
  concat: (...values) => values.join(''),
  substring: (value, start, count) => value.substr(start, count),
  replace: (value, search, replacement) => value.split(search).join(replacement),
  not: value => !value,
  coalesce: (...values) => values.find(value => value !== null && value !== undefined),
  map: (values, transform) => values.map(transform),
  contains: (value, item) => value.includes(item),
  parse: JSON.parse,
  toLower: value => value.toLowerCase(),
  split: (value, delimiter) => value.split(delimiter),
  int: value => Number.parseInt(value, 10)
};
function evaluate(expression) {
  return vm.runInNewContext(expression.slice(1, -1), functions, { timeout: 100 });
}
function valid(element, value) {
  if (element.constraints.required && !value) return false;
  const validations = element.constraints.validations || [{ regex: element.constraints.regex }];
  return validations.every(rule => (!rule.regex || new RegExp(rule.regex).test(value)) &&
    (!rule.isValid || evaluate(rule.isValid)));
}
function credentials(adminId, secret) {
  state = { postgres: { administratorLogin: adminId, administratorPassword: secret } };
  return valid(login, adminId) && valid(password, secret);
}

assert.equal(form.view.outputs.kind, 'Subscription');
assert.equal(elements.basics.location.label, '\ubc30\ud3ec \uc704\uce58');
assert.equal(elements.basics.location.defaultValue.value, 'koreacentral');
assert.equal(elements.basics.location.type, 'Microsoft.Common.DropDown');
assert.equal(elements.basics.locations.request.method, 'GET');
assert.match(elements.basics.location.toolTip, /deployment records only/);
assert.equal(login.type, 'Microsoft.Common.TextBox');
assert.equal(password.type, 'Microsoft.Common.PasswordBox');
assert.equal(password.options.hideConfirmation, false);
assert.equal(Object.hasOwn(password, 'defaultValue'), false);
assert.equal(evaluate(login.defaultValue), 'pgadmin1030');
functions.utcNow = () => '2027-01-02T00:00:00.000Z';
assert.equal(evaluate(login.defaultValue), 'pgadmin0102');
assert.match(elements.postgres.passwordRules.options.text, /12-128.*3 of/);
assert.equal(credentials('pgadmin1030', undefined), false);
for (const secret of ['WorkshopABC123', 'WorkshopABC!!', 'WORKSHOP123!!', 'workshop123!!']) {
  assert.equal(credentials('pgadmin1030', secret), true, 'Each 3-of-4 combination must pass.');
}
for (const adminId of ['', 'admin', 'ADMINISTRATOR', 'postgres', 'azuresu', 'root', 'pg_test', 'bad-name', 'admin name', 'a'.repeat(64)]) {
  assert.equal(credentials(adminId, 'Workshop123!!'), false, 'Invalid ID must fail.');
}
assert.equal(credentials('a'.repeat(63), 'Workshop123!!'), true);
for (const secret of ['', 'Short12!', 'workshoponly', 'WORKSHOP1234', 'workshop1234', 'A1!' + 'a'.repeat(126), 'Xpgadmin1030!12', 'XPGADMIN1030!12']) {
  assert.equal(credentials('pgadmin1030', secret), false, 'Invalid password must fail.');
}
assert.equal(credentials('pgadmin1030', 'A1!' + 'a'.repeat(125)), true);
state = {
  basics: { subscription: { subscriptionId: 'test-subscription' }, location: 'koreacentral',
    locations: { value: [{ name: 'koreacentral', displayName: 'Korea Central' }, { name: 'eastus', displayName: 'East US' }] },
    prefix: 'testlab', expiry: '2026-10-31', allowedClientCidrs: '203.0.113.10/32,198.51.100.20/32' },
  postgres: { administratorLogin: 'pgadmin1030', administratorPassword: 'SyntheticOnly123!' },
  capacity: { aksVmSize: 'Standard_D4s_v5', aksNodeCount: '2', kubernetesVersion: '',
    useEphemeralOsDisk: false, postgresVmSize: 'Standard_D2ds_v5' }
};
assert.equal(valid(elements.basics.allowedClientCidrs, state.basics.allowedClientCidrs), true);
for (const value of ['0.0.0.0/0', '256.0.0.1/32', '["203.0.113.10/32"]']) {
  assert.equal(valid(elements.basics.allowedClientCidrs, value), false);
}
assert.equal(evaluate(form.view.outputs.subscriptionId), 'test-subscription');
assert.equal(evaluate(form.view.outputs.location), 'koreacentral');
assert.equal(evaluate(elements.basics.locations.request.path), '/subscriptions/test-subscription/locations?api-version=2022-12-01');
assert.equal(JSON.stringify(evaluate(elements.basics.location.constraints.allowedValues)),
  '[{"label":"Korea Central","value":"koreacentral"},{"label":"East US","value":"eastus"}]');
state.basics.location = 'eastus';
assert.equal(evaluate(form.view.outputs.location), 'eastus');
assert.equal(evaluate(form.view.outputs.parameters.aksNodeCount), 2);
assert.equal(JSON.stringify(evaluate(form.view.outputs.parameters.allowedClientCidrs)),
  '["203.0.113.10/32","198.51.100.20/32"]');
for (const [name, expression] of Object.entries(form.view.outputs.parameters)) {
  assert.notEqual(evaluate(expression), undefined, `Output is not bound: ${name}`);
}
console.log('Portal form checks passed: visible dated ID, secure password confirmation, credential rules, subscription scope and parameter bindings.');