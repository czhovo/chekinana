const { SCANNER_AUTH_PASSED_KEY } = require("../../utils/config");
const TAB_URLS = [
  "/pages/index/index",
  "/pages/calendar/calendar",
  "/pages/idols/idols",
  "/pages/gallery/gallery",
  "/pages/settings/settings"
];

Component({
  properties: {
    active: {
      type: String,
      value: "scanner"
    },
    scannerVariant: {
      type: String,
      value: "scanner"
    }
  },

  data: {
    items: [
      { id: "scanner", label: "Scanner", icon: "scanner", url: "/pages/auth/auth" },
      { id: "calendar", label: "Calendar", icon: "calendar", url: "/pages/calendar/calendar" },
      { id: "idols", label: "Idols", icon: "idols", url: "/pages/idols/idols" },
      { id: "gallery", label: "Gallery", icon: "gallery", url: "/pages/gallery/gallery" },
      { id: "settings", label: "Settings", icon: "settings", url: "/pages/settings/settings" }
    ]
  },

  methods: {
    noop() {},

    onNavTap(event) {
      const itemId = event.currentTarget.dataset.id;
      let url = event.currentTarget.dataset.url;
      if (!url) return;
      if (itemId === this.properties.active) return;

      if (itemId === "scanner" && this.properties.scannerVariant === "map") {
        url = "/pages/izaya7-map/izaya7-map";
      } else if (itemId === "scanner") {
        if (wx.getStorageSync(SCANNER_AUTH_PASSED_KEY)) {
          url = "/pages/index/index";
        }
      }

      if (TAB_URLS.indexOf(url) >= 0) {
        wx.switchTab({ url });
        return;
      }

      wx.reLaunch({ url });
    }
  }
});
