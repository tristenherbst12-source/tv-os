/* Time-of-day wallpaper, shared by every page: sets the --bg and --b1..--b4 colours and crossfades
   (4 s, done in CSS) when the time slot or the theme changes. */
window.TV = window.TV || {};

TV.wallpaper = {
  key: '',
  /* settings.wallpaper: 'blue' | 'sage' | 'rotate'. onChange(part, palette) runs when the slot changes. */
  start(settings, onChange) {
    const apply = () => {
      const d = new Date();
      const part = TV.dayPart(d);
      const theme = TV.themeFor(settings.wallpaper, d);
      const key = theme + '/' + part;
      if (key === this.key) return;
      this.key = key;
      const p = TV.THEMES[theme][part], s = document.documentElement.style;
      s.setProperty('--bg', p.bg);
      ['--b1', '--b2', '--b3', '--b4'].forEach((v, i) => s.setProperty(v, p.b[i]));
      if (onChange) onChange(part, p);
    };
    apply();
    setInterval(apply, 15000);
    this.refresh = () => { this.key = ''; apply(); };
  }
};
