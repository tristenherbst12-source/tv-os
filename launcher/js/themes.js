/* Wallpaper palettes. Blue is the default; Sage is the kept alternative (design/index-sage.html). */
window.TV = window.TV || {};

TV.THEMES = {
  blue: {
    morning:{name:'Morning', bg:'#0a1426', b:['#2a5a9c','#1b3f78','#3a6fb5','#142f5e']},
    day:    {name:'Day',     bg:'#08111f', b:['#1f4d8f','#163a6e','#2c62a8','#0f2a52']},
    evening:{name:'Evening', bg:'#070d1a', b:['#1a3f78','#122e5c','#24529a','#0c2147']},
    night:  {name:'Night',   bg:'#050a14', b:['#14325f','#0e2449','#1c427a','#091a36']}
  },
  sage: {
    morning:{name:'Morning', bg:'#141a10', b:['#a3b58c','#7d8a45','#c2cfa8','#5f6b32']},
    day:    {name:'Day',     bg:'#121810', b:['#9caf88','#6b7a3a','#b8c79f','#808b4a']},
    evening:{name:'Evening', bg:'#11150c', b:['#8a9c74','#5c6a2e','#a7b58a','#4a5526']},
    night:  {name:'Night',   bg:'#0b0f08', b:['#6f8260','#4b5726','#87987a','#3a441e']}
  }
};

/* Time-of-day slot: morning 05-11, day 11-17, evening 17-21, night 21-05. */
TV.dayPart = function (d) {
  const h = d.getHours();
  return h >= 5 && h < 11 ? 'morning' : h >= 11 && h < 17 ? 'day' : h >= 17 && h < 21 ? 'evening' : 'night';
};

/* 'blue' | 'sage' | 'rotate'. Rotate alternates the palette once a day (blue on even days). */
TV.themeFor = function (setting, d) {
  if (setting === 'sage') return 'sage';
  if (setting === 'rotate') {
    const day = Math.floor((d.getTime() - d.getTimezoneOffset() * 60000) / 86400000);
    return day % 2 === 0 ? 'blue' : 'sage';
  }
  return 'blue';
};
