export default {
  mounted() {
    this.audio = this.el.querySelector("audio")
    this.playButton = this.el.querySelector("[data-preview-play]")
    this.playIcon = this.el.querySelector("[data-preview-play-icon]")
    this.time = this.el.querySelector("[data-preview-time]")
    this.progress = this.el.querySelector("[data-preview-progress]")
    this.start = Number.parseFloat(this.el.dataset.start || "0")

    this.seekToStart = () => this.seek(this.start)
    this.update = () => this.updateUi()

    this.audio.addEventListener("loadedmetadata", this.seekToStart)
    this.audio.addEventListener("timeupdate", this.update)
    this.audio.addEventListener("play", this.update)
    this.audio.addEventListener("pause", this.update)

    this.el.addEventListener("click", (event) => {
      const action = event.target.closest("[data-preview-action]")?.dataset.previewAction
      if (!action) return

      if (action === "toggle") this.toggle()
      if (action === "back") this.nudge(-Number.parseFloat(this.el.dataset.jumpBackward || "15"))
      if (action === "forward") this.nudge(Number.parseFloat(this.el.dataset.jumpForward || "30"))
    })
  },

  destroyed() {
    this.audio.pause()
    this.audio.removeEventListener("loadedmetadata", this.seekToStart)
    this.audio.removeEventListener("timeupdate", this.update)
    this.audio.removeEventListener("play", this.update)
    this.audio.removeEventListener("pause", this.update)
  },

  toggle() {
    if (this.audio.paused) {
      this.audio.play().catch(() => {})
    } else {
      this.audio.pause()
    }
    this.updateUi()
  },

  nudge(seconds) {
    this.seek(this.audio.currentTime + seconds)
  },

  seek(seconds) {
    if (Number.isNaN(this.audio.duration)) return
    this.audio.currentTime = Math.min(Math.max(seconds, 0), this.audio.duration)
    this.updateUi()
  },

  updateUi() {
    const current = this.audio.currentTime || this.start || 0
    const duration = Number.isNaN(this.audio.duration) ? 0 : this.audio.duration

    if (this.playIcon) {
      this.playIcon.className = this.audio.paused ? "hero-play-solid size-6" : "hero-pause-solid size-6"
    }

    if (this.playButton) {
      this.playButton.setAttribute("aria-label", this.audio.paused ? "Play preview" : "Pause preview")
    }

    if (this.time) {
      this.time.textContent = duration > 0 ? `${this.format(current)} / ${this.format(duration)}` : this.format(current)
    }

    if (this.progress) {
      this.progress.style.width = duration > 0 ? `${Math.min((current / duration) * 100, 100)}%` : "0%"
    }
  },

  format(seconds) {
    const total = Math.max(Math.floor(seconds || 0), 0)
    const h = Math.floor(total / 3600)
    const m = Math.floor((total % 3600) / 60)
    const s = total % 60
    return h > 0
      ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`
      : `${m}:${String(s).padStart(2, "0")}`
  },
}
