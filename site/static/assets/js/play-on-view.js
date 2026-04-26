(() => {
  const videos = document.querySelectorAll('video.feature__image');
  if (!videos.length) return;

  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (reduceMotion) return;

  if (!('IntersectionObserver' in window)) {
    videos.forEach((v) => v.play().catch(() => {}));
    return;
  }

  const io = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        const v = entry.target;
        if (entry.isIntersecting) {
          v.play().catch(() => {});
        } else {
          v.pause();
        }
      });
    },
    { threshold: 0.35 }
  );

  videos.forEach((v) => io.observe(v));
})();
