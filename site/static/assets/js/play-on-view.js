(() => {
  const videos = document.querySelectorAll('video.feature__image');
  if (!videos.length) return;

  // Hover (or keyboard focus) reveals native controls so a viewer can
  // scrub. Touch devices have no hover, so show controls outright.
  const noHover = window.matchMedia('(hover: none)').matches;
  if (noHover) {
    videos.forEach((v) => v.setAttribute('controls', ''));
  } else {
    videos.forEach((v) => {
      const show = () => v.setAttribute('controls', '');
      const hide = () => v.removeAttribute('controls');
      v.addEventListener('mouseenter', show);
      v.addEventListener('mouseleave', hide);
      v.addEventListener('focusin', show);
      v.addEventListener('focusout', hide);
    });
  }

  // Autoplay-on-view, skipped for users who prefer reduced motion.
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
