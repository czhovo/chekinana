const { SCANNER_AUTH_PASSED_KEY } = require("../utils/config");

Component({
  data: {
    selected: 0,
    items: [
      { id: "scanner", label: "Scanner", icon: "scanner", url: "/pages/index/index" },
      { id: "calendar", label: "Calendar", icon: "calendar", url: "/pages/calendar/calendar" },
      { id: "idols", label: "Idols", icon: "idols", url: "/pages/idols/idols" },
      { id: "gallery", label: "Gallery", icon: "gallery", url: "/pages/gallery/gallery" },
      { id: "settings", label: "Settings", icon: "settings", url: "/pages/settings/settings" }
    ]
  },

  methods: {
    noop() {},

    onNavTap(event) {
      const index = Number(event.currentTarget.dataset.index);
      const item = this.data.items[index];
      if (!item || index === this.data.selected) return;

      if (item.id === "scanner" && !wx.getStorageSync(SCANNER_AUTH_PASSED_KEY)) {
        wx.reLaunch({ url: "/pages/auth/auth" });
        return;
      }

      wx.switchTab({ url: item.url });
    }
  }
});
