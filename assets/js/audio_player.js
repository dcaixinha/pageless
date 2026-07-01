// AudioPlayer hook: drives the persistent <audio> element for the player
// LiveView. Adapted from the fly-apps/live_beats player, reworked for
// long-form audiobook playback (resume, seeking, speed, progress sync).
export default {
  mounted() {
    this.player = this.el.querySelector("audio")
    this.progressTimer = null
    this.lastReported = 0
    this.lastPositionReported = 0
    this.chapters = []
    this.bookDuration = 0
    this.useChapterTrack = true

    // Browsers block autoplay until a user gesture. Unlock on first click.
    this.enableAudio = () => {
      if (this.player.src && this.player.readyState === 0) {
        this.player.play().catch(() => {})
        this.player.pause()
      }
      document.removeEventListener("click", this.enableAudio)
    }
    document.addEventListener("click", this.enableAudio)

    this.handleEvent("play", ({url, token, position, speed, title, artist, duration, chapters, use_chapter_track}) => {
      const fullUrl = `${url}?token=${encodeURIComponent(token)}`
      if (this.player.src.split("?")[0] !== url.split("?")[0]) {
        this.player.src = fullUrl
      }
      this.player.playbackRate = speed || 1.0
      this.chapters = Array.isArray(chapters) ? chapters : []
      this.bookDuration = duration || 0
      this.useChapterTrack = use_chapter_track !== false

      const start = () => {
        if (position && position > 0) {
          this.player.currentTime = position
        }
        // Paint the progress bar/elapsed time right away so it reflects the
        // starting position before the periodic timer kicks in.
        this.updateProgress()
        this.play()
        this.player.removeEventListener("loadedmetadata", start)
      }
      if (this.player.readyState >= 1) {
        start()
      } else {
        this.player.addEventListener("loadedmetadata", start)
      }

      if ("mediaSession" in navigator) {
        navigator.mediaSession.metadata = new MediaMetadata({title, artist})
      }
    })

    this.handleEvent("pause", () => this.pause())
    this.handleEvent("resume", () => this.play())
    this.handleEvent("seek", ({position}) => this.seekTo(position))
    this.handleEvent("nudge", ({delta}) => this.nudge(delta))
    this.handleEvent("set_speed", ({speed}) => {
      this.player.playbackRate = speed
    })
    this.handleEvent("settings", ({use_chapter_track}) => {
      this.useChapterTrack = use_chapter_track !== false
      this.updateProgress()
    })

    // Scrubber click: ratio is relative to the *current chapter*, so map it to
    // an absolute book-time within that chapter's range.
    this.el.addEventListener("player:seek-chapter", (e) => {
      const ratio = e.detail.ratio
      const found = this.chapterAt(this.player.currentTime)
      if (found) {
        const {chapter} = found
        const end = chapter.end || this.bookDuration || this.player.duration
        this.seekTo(chapter.start + ratio * (end - chapter.start))
      } else {
        this.seekTo(ratio * (this.bookDuration || this.player.duration))
      }
    })

    this.player.addEventListener("play", () => {
      this.pushEvent("playing", {playing: true})
      this.startProgressTimer()
    })
    this.player.addEventListener("pause", () => {
      this.pushEvent("playing", {playing: false})
      clearInterval(this.progressTimer)
      this.reportProgress(true)
    })
    // timeupdate fires ~4x/sec during playback; drives smooth UI updates even
    // if the interval timer is throttled in a background tab.
    this.player.addEventListener("timeupdate", () => this.updateProgress())
    // Repaint as soon as metadata/seeked so the bar reflects the position even
    // while paused (e.g. autoplay was blocked).
    this.player.addEventListener("loadedmetadata", () => this.updateProgress())
    this.player.addEventListener("seeked", () => this.updateProgress())
    this.player.addEventListener("ended", () => {
      clearInterval(this.progressTimer)
      this.reportProgress(true)
      this.pushEvent("ended", {})
    })

    // MediaSession transport controls (lock screen / keyboard media keys).
    if ("mediaSession" in navigator) {
      navigator.mediaSession.setActionHandler("play", () => this.play())
      navigator.mediaSession.setActionHandler("pause", () => this.pause())
      navigator.mediaSession.setActionHandler("seekbackward", () => this.nudge(-15))
      navigator.mediaSession.setActionHandler("seekforward", () => this.nudge(30))
    }
  },

  destroyed() {
    clearInterval(this.progressTimer)
    document.removeEventListener("click", this.enableAudio)
  },

  startProgressTimer() {
    clearInterval(this.progressTimer)
    this.progressTimer = setInterval(() => this.updateProgress(), 250)
  },

  play() {
    // The "play"/"pause" media events drive the progress timer, so we only need
    // to kick off playback here. Autoplay can be rejected before a user
    // gesture; if so we paint the current position and stay paused.
    const p = this.player.play()
    if (p && p.catch) {
      p.catch(() => this.updateProgress())
    }
  },

  pause() {
    this.player.pause()
  },

  seekTo(position) {
    if (isNaN(this.player.duration)) return
    this.player.currentTime = Math.min(Math.max(position, 0), this.player.duration)
    this.updateProgress()
  },

  nudge(delta) {
    if (!isNaN(this.player.duration)) {
      this.seekTo(this.player.currentTime + delta)
    }
  },

  // Returns the chapter containing the given book-time, with its 0-based
  // ordinal among all chapters, or null when chapter tracking is off or there
  // are no chapters (callers then fall back to whole-book progress).
  chapterAt(time) {
    if (!this.useChapterTrack || !this.chapters.length) return null
    for (let i = this.chapters.length - 1; i >= 0; i--) {
      if (time >= this.chapters[i].start) {
        return {chapter: this.chapters[i], ordinal: i}
      }
    }
    return {chapter: this.chapters[0], ordinal: 0}
  },

  updateProgress() {
    if (isNaN(this.player.duration)) return
    const time = this.player.currentTime
    const bookDuration = this.bookDuration || this.player.duration

    // Look the display elements up lazily: they live inside an `<%= if @book %>`
    // block and only exist once a book is loaded (so they may not have existed
    // when the hook mounted, and can be re-created on later renders).
    const progress = this.el.querySelector("#player-progress")
    const elapsedEl = this.el.querySelector("#player-chapter-elapsed")
    const remainingEl = this.el.querySelector("#player-chapter-remaining")
    const titleEl = this.el.querySelector("#player-chapter-title")

    const found = this.chapterAt(time)
    if (found) {
      const {chapter, ordinal} = found
      const chapStart = chapter.start
      const chapEnd = chapter.end || bookDuration
      const chapDuration = Math.max(chapEnd - chapStart, 0.001)
      const inChapter = Math.min(Math.max(time - chapStart, 0), chapDuration)
      const pct = (inChapter / chapDuration) * 100
      const bookPct = bookDuration > 0 ? Math.round((time / bookDuration) * 100) : 0

      if (progress) progress.style.width = `${pct}%`
      if (elapsedEl) {
        elapsedEl.innerText = `${this.formatTime(inChapter)} / ${bookPct}%`
      }
      if (remainingEl) {
        remainingEl.innerText = `-${this.formatTime(chapDuration - inChapter)}`
      }
      if (titleEl) {
        titleEl.innerText = `${chapter.title} (${ordinal + 1} of ${this.chapters.length})`
      }
    } else {
      // Whole-book progress (chapter track disabled or no chapters).
      const pct = bookDuration > 0 ? (time / bookDuration) * 100 : 0
      const bookPct = bookDuration > 0 ? Math.round((time / bookDuration) * 100) : 0
      if (progress) progress.style.width = `${pct}%`
      if (elapsedEl) elapsedEl.innerText = `${this.formatTime(time)} / ${bookPct}%`
      if (remainingEl) remainingEl.innerText = `-${this.formatTime(bookDuration - time)}`
      if (titleEl) titleEl.innerText = ""
    }

    this.reportProgress(false)
  },

  // Throttle UI position broadcasts to 2/sec and persistence to roughly every 5 seconds.
  reportProgress(force) {
    const now = Date.now()
    const payload = {
      position: this.player.currentTime,
      duration: this.player.duration || 0
    }

    if (force || now - this.lastPositionReported >= 500) {
      this.lastPositionReported = now
      this.pushEvent("position", payload)
    }

    if (!force && now - this.lastReported < 5000) return
    this.lastReported = now
    this.pushEvent("progress", payload)
  },

  formatTime(seconds) {
    const s = Math.floor(seconds)
    const h = Math.floor(s / 3600)
    const m = Math.floor((s % 3600) / 60)
    const sec = String(s % 60).padStart(2, "0")
    return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${sec}` : `${m}:${sec}`
  }
}
