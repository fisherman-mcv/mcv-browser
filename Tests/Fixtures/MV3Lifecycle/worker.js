const increment = async (key) => {
  const value = await chrome.storage.local.get({[key]: 0});
  await chrome.storage.local.set({[key]: value[key] + 1});
};
globalThis.fixtureLoaded = true;
chrome.runtime.onStartup.addListener(() => increment('startupCount'));
chrome.runtime.onInstalled.addListener(() => increment('installedCount'));
chrome.tabs.onCreated.addListener(() => increment('createdCount'));
chrome.tabs.onRemoved.addListener(() => increment('removedCount'));
