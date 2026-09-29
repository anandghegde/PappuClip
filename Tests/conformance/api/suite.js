// The conformance suite's API section (implementation plan, M3 week 7): the `popclip` object and the
// host calls behind it (JS-3 to JS-8, JS-11, JS-17, SEC-7b), checked from inside a world as an
// extension would see them.
//
// A module, not an action script: `pappuclip run Tests/conformance/api/suite.js` calls its `test`,
// which resolves with "ok" or rejects with one line per failure, so the command exits 0 or 1 (DEV-2).
// It is run with no grants, and its host calls are answered by `pappuclip run`'s headless host, which
// refuses what the app refuses and performs nothing. PappuCLITests runs it
// (`theAPISectionOfTheConformanceSuitePasses`) and also checks the calls it made reached the host.
//
// What a headless run cannot observe — that a paste lands in the right app, that a URL opens, what a
// panel looks like — is the action-lifecycle suite's and the manual checklists', not this file's.

const failures = [];

async function check(name, body) {
  try {
    const result = await body();
    if (result !== true) failures.push(name + ': got ' + JSON.stringify(result));
  } catch (error) {
    failures.push(name + ': threw ' + (error && error.message));
  }
}

async function rejection(promise) {
  try {
    await promise;
    return '(resolved)';
  } catch (error) {
    return error.message;
  }
}

export async function test(input, options, context) {
  const methods = [
    'pasteText', 'pasteContent', 'copyText', 'copyContent', 'performCommand', 'showText', 'showResult',
    'promptText', 'showSuccess', 'showFailure', 'showSettings', 'signInRequiredError', 'settingsRequiredError',
    'appear', 'pressKey', 'pressKeys', 'runAppleScript', 'runAppleScriptFile', 'runShortcut', 'runShellScript',
    'runShellScriptFile', 'performService', 'revealFile', 'openUrl', 'openTemplateUrl', 'share',
  ];

  await check('JS-3: the code is called with input, options and context', () =>
    input === popclip.input && options === popclip.options && context === popclip.context);
  await check('JS-3: popclip.input has its text', () =>
    typeof popclip.input.text === 'string' && typeof popclip.input.matchedText === 'string');
  await check('JS-3: popclip.modifiers are four booleans', () =>
    ['shift', 'control', 'option', 'command'].every((key) => typeof popclip.modifiers[key] === 'boolean'));
  await check('JS-3: pappuclip is popclip', () => pappuclip === popclip);
  await check('JS-3: popclip is frozen', () => Object.isFrozen(popclip));
  await check('JS-4: every documented method is there', () => {
    const missing = methods.filter((name) => typeof popclip[name] !== 'function');
    return missing.length === 0 ? true : missing;
  });

  await check('JS-5: pasteText and copyText resolve', async () =>
    (await popclip.pasteText('pasted')) === undefined && (await popclip.copyText('copied')) === undefined);
  await check('JS-7: the clipboard reads back what was copied', async () => {
    await popclip.copyText('round trip');
    return pasteboard.text === 'round trip';
  });
  await check('JS-7: pasteboard.text can be set', () => {
    pasteboard.text = 'set directly';
    return pasteboard.text === 'set directly';
  });
  await check('JS-5: performCommand takes cut, copy and paste only', async () =>
    (await popclip.performCommand('copy')) === undefined
      && (() => { try { popclip.performCommand('delete'); return false; } catch (error) { return error instanceof TypeError; } })());
  await check('JS-6: openUrl resolves', async () => (await popclip.openUrl('https://example.com/')) === undefined);

  await check('JS-11: signInRequiredError and settingsRequiredError carry the prefixes', () =>
    popclip.signInRequiredError('x').message === 'Not signed in: x'
      && popclip.settingsRequiredError().message === 'Settings error');
  await check('JS-18: promptText needs a label', () => {
    try {
      popclip.promptText({});
      return false;
    } catch (error) {
      return error instanceof TypeError;
    }
  });

  await check('SEC-7b: pressKey needs the synthetic-input grant', async () =>
    (await rejection(popclip.pressKey('cmd b'))) === 'pressKeys needs the synthetic-input permission, which this extension does not have.');
  await check('SEC-7b: performService needs the synthetic-input grant', async () =>
    (await rejection(popclip.performService('Make New Sticky Note', 'x'))) === 'performService needs the synthetic-input permission, which this extension does not have.');
  await check('SEC-7b: a shell script needs the script grant', async () =>
    (await rejection(popclip.runShellScript('echo hi'))).includes('script permission'));
  // The refusal is the app's and is logged as the request fails; axios, as in a browser, says only
  // that the network failed.
  await check('SEC-7b: a request needs the network grant', async () =>
    (await rejection(require('axios').get('https://example.com/'))) === 'Network Error');

  await check('JS-8: util.buildQuery and util.parseQuery are inverses', () => {
    const query = util.buildQuery({ q: 'a b', n: 1, gone: undefined });
    const back = util.parseQuery(query);
    return query === 'q=a%20b&n=1' && back.q === 'a b' && back.n === '1';
  });
  await check('JS-8: util.randomUuid is a UUID', () => /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(util.randomUuid()));
  await check('JS-8: util.base64Encode round-trips', () => util.base64Decode(util.base64Encode('héllo')) === 'héllo');

  if (failures.length > 0) throw new Error(failures.length + ' failed:\n' + failures.join('\n'));
  return 'ok';
}
