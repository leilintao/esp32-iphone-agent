// DOM-only label regression. These fixtures are never served as phone screenshots.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
function element() {
  return {style: {}, children: [], setAttribute() {},
    append(...items) {this.children.push(...items);}, replaceChildren() {this.children = [];}};
}
const nodes = new Map();
const context = vm.createContext({
  document: {getElementById(id) {if (!nodes.has(id)) nodes.set(id, element()); return nodes.get(id);}, createElement: element},
  fetch: () => new Promise(() => {}), setTimeout() {},
});
const html = fs.readFileSync(`${__dirname}/live_preview.html`, 'utf8');
vm.runInContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], context);
for (const role of ['diagnostic', 'actor', 'planner']) {
  context.testState = {status: 'test only', events: [{kind: 'look', id: role, role, time: 0, frameAge: 0, task: 'unit fixture'}]};
  vm.runInContext('render(testState)', context);
  const text = nodes.get('picture-title').textContent;
  const action = nodes.get('list').children[0].children[2].textContent;
  if (role === 'diagnostic') {
    assert.match(text, /非模型调用/);
    assert.match(action, /未请求模型，未执行点击/);
    assert.match(nodes.get('shot').alt, /未发送给模型/);
  } else {
    assert.doesNotMatch(text, /诊断/);
    assert.doesNotMatch(action, /仅检查截图传输/);
  }
}
console.log('Preview labels passed for diagnostic, actor and planner; no images fetched');
