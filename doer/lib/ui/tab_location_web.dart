import 'dart:js_interop';

import 'dart:ui_web' as ui_web;

import 'package:web/web.dart' as web;

const _tabs = ['agenda', 'goals', 'settings'];
int readTab() {
  final index = _tabs.indexOf(web.window.location.hash.replaceFirst('#/', ''));
  return index < 0 ? 0 : index;
}

void writeTab(int tab) {
  final hash = '#/${_tabs[tab]}';
  if (web.window.location.hash != hash) {
    web.window.history.pushState(null, '', hash);
  }
}

void Function() listenTab(void Function(int) changed) {
  final listener = ((web.Event event) => changed(readTab())).toJS;
  web.window.addEventListener('hashchange', listener);
  web.window.addEventListener('popstate', listener);
  return () {
    web.window.removeEventListener('hashchange', listener);
    web.window.removeEventListener('popstate', listener);
  };
}

// The shell owns tab hashes; Navigator only owns in-app editor/dialog routes.
void installTabRouting() => ui_web.urlStrategy = null;
