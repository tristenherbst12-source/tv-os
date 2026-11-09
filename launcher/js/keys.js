/* Turns a keydown into a launcher action using config/keymap.json ("launcher" section).
   An entry matches either e.key or e.code, so both "Enter" and "NumpadEnter" style names work. */
window.TV = window.TV || {};

TV.keys = {
  map: {},
  load(keymap) {
    const m = {};
    const actions = (keymap && keymap.launcher) || {};
    Object.keys(actions).forEach(action => {
      (actions[action] || []).forEach(k => { if (!(k in m)) m[k] = action; });
    });
    this.map = m;
  },
  action(e) {
    return this.map[e.key] || this.map[e.code] || null;
  }
};
