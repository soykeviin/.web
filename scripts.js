document.addEventListener('DOMContentLoaded', () => {
    const videos = document.querySelectorAll('.video');

    videos.forEach(video => {
        video.addEventListener('click', () => {
            // Si el video está sonando, siléncialo
            if (!video.muted) {
                video.muted = true;
            } else {
                // Si el video está en silencio, silencia todos los videos primero
                videos.forEach(v => v.muted = true);
                // Luego activa el sonido solo en el video clicado
                video.muted = false;
            }
        });
    });
});
