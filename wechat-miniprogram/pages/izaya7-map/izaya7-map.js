// Data downloaded from https://geo.datav.aliyun.com/areas_v3/bound/100000_full.json
const chinaGeoJSON = require("../../data/china-100000-full");
const CANVAS_SELECTOR = "#china-map-canvas";
const CANVAS_INIT_MAX_RETRY = 8;
const WEB_MERCATOR_MAX_LAT = 85.05112878;
const INITIAL_MAP_ZOOM = 4;
const INITIAL_MAP_CENTER_CITY = "武汉";
const RECORD_MARKER_RADIUS = 4.5;
const RECORD_LABEL_FONT_SIZE = 18;
const RECORD_LABEL_PADDING_X = 8;
const RECORD_LABEL_PADDING_Y = 5;
const RECORD_LABEL_GAP = 8;
const RECORD_LABEL_COLLISION_GAP = 4;
const RECORD_LABEL_DETAIL_FONT_SIZE = 12;
const DEFAULT_RECORDS = [
  { city: "武汉", quantity: 100, date: "2026-04-19" },
  { city: "北京", quantity: 200, date: "2026-06-06" },
  { city: "西安", quantity: 300, date: "2026-06-28" }
];
const CITY_LOCATIONS = {
  "北京": { lng: 116.4074, lat: 39.9042, province: "北京市" },
  "上海": { lng: 121.4737, lat: 31.2304, province: "上海市" },
  "西安": { lng: 108.9398, lat: 34.3416, province: "陕西省" },
  "广州": { lng: 113.2644, lat: 23.1291, province: "广东省" },
  "武汉": { lng: 114.3055, lat: 30.5928, province: "湖北省" },
  "成都": { lng: 104.0665, lat: 30.5723, province: "四川省" },
  "重庆": { lng: 106.5516, lat: 29.563, province: "重庆市" },
  "杭州": { lng: 120.1551, lat: 30.2741, province: "浙江省" },
  "深圳": { lng: 114.0579, lat: 22.5431, province: "广东省" },
  "天津": { lng: 117.2, lat: 39.0842, province: "天津市" },
  "济南": { lng: 117.1201, lat: 36.6512, province: "山东省" },
  "长沙": { lng: 112.9388, lat: 28.2282, province: "湖南省" },
  "福州": { lng: 119.2965, lat: 26.0745, province: "福建省" }
};

Page({
  data: {
    statusText: "地图加载中",
    statusKind: "loading",
    showRecordDialog: false,
    recordCity: "",
    recordDate: "",
    recordQuantity: "",
    recordRemark: "",
    recordErrorText: "",
    selectedRecordId: "",
    editingRecordId: ""
  },

  records: [],
  recordIdSeed: 0,
  labelHitRects: [],
  highlightedProvinceMap: {},
  hasSeededDefaultRecords: false,
  mapPolygons: null,
  mapBounds: null,
  canvasNode: null,
  canvasContext: null,
  canvasWidth: 0,
  canvasHeight: 0,
  canvasDpr: 1,
  canvasRect: null,
  mapBaseTransform: null,
  bitmapImage: null,
  bitmapTransform: null,
  bitmapBuildInProgress: false,
  pendingBitmapBuild: false,
  hasBuiltInitialMap: false,
  resizeTimer: null,
  touchState: null,
  hasDraggedMap: false,
  viewTransform: {
    scale: INITIAL_MAP_ZOOM,
    translateX: 0,
    translateY: 0
  },

  onReady() {
    this.loadChinaGeoJSON();
  },

  onResize() {
    if (!this.mapPolygons || !this.mapBounds) return;
    if (this.resizeTimer) clearTimeout(this.resizeTimer);
    this.resizeTimer = setTimeout(() => {
      this.drawMapWhenCanvasReady(this.mapPolygons, this.mapBounds);
    }, 120);
  },

  onUnload() {
    if (this.resizeTimer) clearTimeout(this.resizeTimer);
    this.touchState = null;
  },

  loadChinaGeoJSON() {
    this.setData({
      statusText: "地图加载中",
      statusKind: "loading"
    });

    this.prepareAndDrawMap(chinaGeoJSON);
  },

  prepareAndDrawMap(geojson) {
    const polygons = this.extractPolygons(geojson);
    const bounds = this.getBounds(polygons);

    if (!polygons.length || !bounds) {
      this.showMapError("地图数据解析失败");
      return;
    }

    this.mapPolygons = polygons;
    this.mapBounds = bounds;
    this.hasBuiltInitialMap = false;
    this.resetMapView();
    this.seedDefaultRecords();
    this.setData({
      statusText: "地图绘制中",
      statusKind: "loading"
    });
    this.drawMapWhenCanvasReady(polygons, bounds);
  },

  extractPolygons(geojson) {
    const features = geojson && Array.isArray(geojson.features) ? geojson.features : [];
    const polygons = [];

    features.forEach((feature) => {
      const geometry = feature && feature.geometry;
      const provinceName = feature && feature.properties ? feature.properties.name : "";
      if (!geometry || !Array.isArray(geometry.coordinates)) return;

      if (geometry.type === "Polygon") {
        this.appendPolygon(polygons, geometry.coordinates, provinceName);
        return;
      }

      if (geometry.type === "MultiPolygon") {
        geometry.coordinates.forEach((polygon) => {
          this.appendPolygon(polygons, polygon, provinceName);
        });
      }
    });

    return polygons;
  },

  appendPolygon(polygons, polygon, provinceName) {
    if (!Array.isArray(polygon)) return;

    const rings = polygon
      .filter((ring) => Array.isArray(ring) && ring.length > 1)
      .map((ring) => ring
        .map((point) => this.projectWebMercatorPoint(point))
        .filter(Boolean))
      .filter((ring) => ring.length > 1);

    if (rings.length) {
      rings.provinceName = provinceName || "";
      polygons.push(rings);
    }
  },

  getBounds(polygons) {
    const bounds = {
      minX: Infinity,
      maxX: -Infinity,
      minY: Infinity,
      maxY: -Infinity
    };

    polygons.forEach((polygon) => {
      polygon.forEach((ring) => {
        ring.forEach((point) => {
          if (!point || !Number.isFinite(point.x) || !Number.isFinite(point.y)) return;

          bounds.minX = Math.min(bounds.minX, point.x);
          bounds.maxX = Math.max(bounds.maxX, point.x);
          bounds.minY = Math.min(bounds.minY, point.y);
          bounds.maxY = Math.max(bounds.maxY, point.y);
        });
      });
    });

    if (
      !Number.isFinite(bounds.minX)
      || !Number.isFinite(bounds.maxX)
      || !Number.isFinite(bounds.minY)
      || !Number.isFinite(bounds.maxY)
      || bounds.maxX <= bounds.minX
      || bounds.maxY <= bounds.minY
    ) {
      return null;
    }

    return bounds;
  },

  projectWebMercatorPoint(point) {
    if (!Array.isArray(point) || point.length < 2) return null;

    const lng = Number(point[0]);
    const lat = Number(point[1]);
    if (!Number.isFinite(lng) || !Number.isFinite(lat)) return null;

    const clampedLat = Math.max(Math.min(lat, WEB_MERCATOR_MAX_LAT), -WEB_MERCATOR_MAX_LAT);
    const latRad = clampedLat * Math.PI / 180;
    const mercatorY = Math.log(Math.tan(Math.PI / 4 + latRad / 2));

    return {
      x: lng,
      y: mercatorY * 180 / Math.PI
    };
  },

  drawMapWhenCanvasReady(polygons, bounds, retryCount = 0) {
    wx.createSelectorQuery()
      .in(this)
      .select(CANVAS_SELECTOR)
      .fields({ node: true, size: true, rect: true }, (canvasInfo) => {
        if (!canvasInfo || !canvasInfo.node || !canvasInfo.width || !canvasInfo.height) {
          if (retryCount < CANVAS_INIT_MAX_RETRY) {
            setTimeout(() => {
              this.drawMapWhenCanvasReady(polygons, bounds, retryCount + 1);
            }, 80);
            return;
          }

          this.showMapError("画布初始化失败");
          return;
        }

        this.canvasNode = canvasInfo.node;
        this.canvasContext = canvasInfo.node.getContext("2d");
        this.canvasWidth = canvasInfo.width;
        this.canvasHeight = canvasInfo.height;
        this.canvasDpr = wx.getSystemInfoSync().pixelRatio || 1;
        this.mapBaseTransform = null;
        canvasInfo.node.width = Math.round(canvasInfo.width * this.canvasDpr);
        canvasInfo.node.height = Math.round(canvasInfo.height * this.canvasDpr);
        this.canvasRect = {
          left: Number(canvasInfo.left || 0),
          top: Number(canvasInfo.top || 0)
        };
        if (!this.hasBuiltInitialMap) {
          this.resetMapView();
          this.hasBuiltInitialMap = true;
        }
        this.rebuildBitmapCache();
      })
      .exec();
  },

  drawVectorMap() {
    if (!this.canvasContext || !this.mapPolygons || !this.mapBounds || !this.canvasWidth || !this.canvasHeight) {
      return;
    }

    const ctx = this.canvasContext;
    const polygons = this.mapPolygons;
    const bounds = this.mapBounds;
    const width = this.canvasWidth;
    const height = this.canvasHeight;
    const xSpan = bounds.maxX - bounds.minX;
    const ySpan = bounds.maxY - bounds.minY;
    const padding = Math.max(8, Math.min(width, height) * 0.03);
    const drawableWidth = Math.max(1, width - padding * 2);
    const drawableHeight = Math.max(1, height - padding * 2);
    const scale = Math.min(drawableWidth / xSpan, drawableHeight / ySpan);
    const mapWidth = xSpan * scale;
    const mapHeight = ySpan * scale;
    const offsetX = (drawableWidth - mapWidth) / 2;
    const offsetY = (drawableHeight - mapHeight) / 2;
    this.mapBaseTransform = { padding, scale, offsetX, offsetY };
    const viewTransform = this.viewTransform || {};
    const zoom = viewTransform.scale || 1;
    const translateX = viewTransform.translateX || 0;
    const translateY = viewTransform.translateY || 0;
    const getCanvasPoint = (point) => {
      const baseX = padding + (point.x - bounds.minX) * scale + offsetX;
      const baseY = padding + (bounds.maxY - point.y) * scale + offsetY;
      return {
        x: baseX * zoom + translateX,
        y: baseY * zoom + translateY
      };
    };

    this.clearCanvas();

    ctx.fillStyle = "#eef0f4";
    polygons.forEach((polygon) => {
      if (!this.highlightedProvinceMap[polygon.provinceName]) return;

      ctx.beginPath();
      this.addPolygonPath(ctx, polygon, getCanvasPoint);
      ctx.fill();
    });

    ctx.beginPath();
    polygons.forEach((polygon) => {
      this.addPolygonPath(ctx, polygon, getCanvasPoint);
    });

    ctx.strokeStyle = "#d1d5db";
    ctx.lineWidth = 1;
    ctx.lineJoin = "round";
    ctx.lineCap = "round";
    ctx.stroke();
    this.drawRecordMarkers(ctx, getCanvasPoint);
    this.drawRecordLabels(ctx, getCanvasPoint);
  },

  addPolygonPath(ctx, polygon, getCanvasPoint) {
    polygon.forEach((ring) => {
      let started = false;
      ring.forEach((point) => {
        if (!point || !Number.isFinite(point.x) || !Number.isFinite(point.y)) return;
        const canvasPoint = getCanvasPoint(point);

        if (!started) {
          ctx.moveTo(canvasPoint.x, canvasPoint.y);
          started = true;
          return;
        }

        ctx.lineTo(canvasPoint.x, canvasPoint.y);
      });

      if (started) ctx.closePath();
    });
  },

  seedDefaultRecords() {
    if (this.hasSeededDefaultRecords) return;

    DEFAULT_RECORDS.forEach((record) => {
      const cityName = this.normalizeCityName(record.city);
      const location = CITY_LOCATIONS[cityName];
      if (!location) return;

      this.records.push(this.createRecord({
        city: cityName,
        date: record.date || "",
        quantity: record.quantity,
        remark: "",
        location
      }));
    });
    this.hasSeededDefaultRecords = true;
    this.refreshHighlightedProvinceMap();
  },

  drawRecordMarkers(ctx, getCanvasPoint) {
    this.records.forEach((record) => {
      if (!record || !record.location || !record.location.projectedPoint) return;

      const canvasPoint = getCanvasPoint(record.location.projectedPoint);
      ctx.beginPath();
      ctx.fillStyle = "#ef0000";
      ctx.arc(canvasPoint.x, canvasPoint.y, RECORD_MARKER_RADIUS, 0, Math.PI * 2);
      ctx.fill();
    });
  },

  drawRecordLabels(ctx, getCanvasPoint) {
    const placedRects = [];
    this.labelHitRects = [];

    ctx.font = `600 ${RECORD_LABEL_FONT_SIZE}px sans-serif`;
    ctx.textBaseline = "middle";
    ctx.textAlign = "left";

    this.records.forEach((record) => {
      if (!record || !record.location || !record.location.projectedPoint) return;

      const text = String(record.quantity || "");
      if (!text) return;

      const metrics = this.getRecordLabelMetrics(ctx, record);
      const anchor = getCanvasPoint(record.location.projectedPoint);
      const rect = this.getRecordLabelRect(anchor, metrics.width, metrics.height, placedRects);
      placedRects.push(rect);
      this.labelHitRects.push(Object.assign({ recordId: record.id }, rect));
      this.drawRecordLabel(ctx, rect, record, metrics);
    });
  },

  getRecordLabelMetrics(ctx, record) {
    const lines = [{ text: String(record.quantity || ""), fontSize: RECORD_LABEL_FONT_SIZE, weight: "600" }];

    if (record.expanded) {
      const detailTexts = [];
      if (record.date) detailTexts.push(this.formatDisplayDate(record.date));
      if (record.remark) detailTexts.push(record.remark);
      detailTexts.forEach((text) => {
        lines.push({ text, fontSize: RECORD_LABEL_DETAIL_FONT_SIZE, weight: "400" });
      });
    }

    const width = lines.reduce((maxWidth, line) => {
      ctx.font = `${line.weight} ${line.fontSize}px sans-serif`;
      return Math.max(maxWidth, ctx.measureText(line.text).width);
    }, 0);
    const textHeight = lines.reduce((sum, line) => sum + line.fontSize + 2, -2);

    return {
      lines,
      width: Math.ceil(width + RECORD_LABEL_PADDING_X * 2),
      height: Math.ceil(textHeight + RECORD_LABEL_PADDING_Y * 2)
    };
  },

  getRecordLabelRect(anchor, width, height, placedRects) {
    const edgePadding = 4;
    const baseGap = RECORD_MARKER_RADIUS + RECORD_LABEL_GAP;
    const candidates = [];

    for (let ring = 0; ring < 8; ring += 1) {
      const gap = baseGap + ring * (height + RECORD_LABEL_GAP);
      candidates.push(
        { x: anchor.x - width / 2, y: anchor.y - height - gap },
        { x: anchor.x + gap, y: anchor.y - height - gap },
        { x: anchor.x - width - gap, y: anchor.y - height - gap },
        { x: anchor.x + gap, y: anchor.y + gap },
        { x: anchor.x - width - gap, y: anchor.y + gap },
        { x: anchor.x + gap, y: anchor.y - height / 2 },
        { x: anchor.x - width - gap, y: anchor.y - height / 2 },
        { x: anchor.x - width / 2, y: anchor.y + gap }
      );
    }

    for (let i = 0; i < candidates.length; i += 1) {
      const rect = this.clampRecordLabelRect(
        Object.assign({ width, height }, candidates[i]),
        edgePadding
      );
      if (!this.hasLabelCollision(rect, placedRects)) return rect;
    }

    return this.clampRecordLabelRect(
      {
        x: anchor.x + baseGap,
        y: anchor.y - height - baseGap,
        width,
        height
      },
      edgePadding
    );
  },

  clampRecordLabelRect(rect, edgePadding) {
    const maxX = Math.max(edgePadding, this.canvasWidth - rect.width - edgePadding);
    const maxY = Math.max(edgePadding, this.canvasHeight - rect.height - edgePadding);

    return {
      x: Math.max(edgePadding, Math.min(rect.x, maxX)),
      y: Math.max(edgePadding, Math.min(rect.y, maxY)),
      width: rect.width,
      height: rect.height
    };
  },

  hasLabelCollision(rect, placedRects) {
    return placedRects.some((placedRect) => this.rectsIntersect(rect, placedRect, RECORD_LABEL_COLLISION_GAP));
  },

  rectsIntersect(firstRect, secondRect, gap) {
    return !(
      firstRect.x + firstRect.width + gap <= secondRect.x
      || secondRect.x + secondRect.width + gap <= firstRect.x
      || firstRect.y + firstRect.height + gap <= secondRect.y
      || secondRect.y + secondRect.height + gap <= firstRect.y
    );
  },

  drawRecordLabel(ctx, rect, record, metrics) {
    this.drawRoundRect(ctx, rect.x, rect.y, rect.width, rect.height, 8);
    ctx.fillStyle = "rgba(255, 255, 255, 0.5)";
    ctx.fill();
    ctx.strokeStyle = "#111827";
    ctx.lineWidth = record.id === this.data.selectedRecordId ? 1.6 : 1;
    ctx.stroke();
    ctx.fillStyle = "#111827";
    ctx.textBaseline = "top";
    ctx.textAlign = "center";
    let y = rect.y + RECORD_LABEL_PADDING_Y;
    metrics.lines.forEach((line) => {
      ctx.font = `${line.weight} ${line.fontSize}px sans-serif`;
      ctx.fillText(line.text, rect.x + rect.width / 2, y);
      y += line.fontSize + 2;
    });
    ctx.textAlign = "left";
  },

  drawRoundRect(ctx, x, y, width, height, radius) {
    const rectRadius = Math.min(radius, width / 2, height / 2);

    ctx.beginPath();
    ctx.moveTo(x + rectRadius, y);
    ctx.lineTo(x + width - rectRadius, y);
    ctx.quadraticCurveTo(x + width, y, x + width, y + rectRadius);
    ctx.lineTo(x + width, y + height - rectRadius);
    ctx.quadraticCurveTo(x + width, y + height, x + width - rectRadius, y + height);
    ctx.lineTo(x + rectRadius, y + height);
    ctx.quadraticCurveTo(x, y + height, x, y + height - rectRadius);
    ctx.lineTo(x, y + rectRadius);
    ctx.quadraticCurveTo(x, y, x + rectRadius, y);
    ctx.closePath();
  },

  clearCanvas() {
    const ctx = this.canvasContext;
    if (!ctx) return;

    if (ctx.setTransform) {
      ctx.setTransform(this.canvasDpr, 0, 0, this.canvasDpr, 0, 0);
    }
    ctx.clearRect(0, 0, this.canvasWidth, this.canvasHeight);
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, this.canvasWidth, this.canvasHeight);
  },

  rebuildBitmapCache() {
    if (!this.canvasNode || !this.canvasContext || !this.canvasWidth || !this.canvasHeight) return;
    if (this.bitmapBuildInProgress) {
      this.pendingBitmapBuild = true;
      return;
    }

    this.bitmapBuildInProgress = true;
    this.pendingBitmapBuild = false;
    this.drawVectorMap();

    wx.canvasToTempFilePath({
      canvas: this.canvasNode,
      x: 0,
      y: 0,
      width: this.canvasWidth,
      height: this.canvasHeight,
      destWidth: Math.round(this.canvasWidth * this.canvasDpr),
      destHeight: Math.round(this.canvasHeight * this.canvasDpr),
      success: (res) => {
        this.loadBitmapImage(res.tempFilePath, this.copyViewTransform());
      },
      fail: () => {
        this.bitmapBuildInProgress = false;
        this.setData({
          statusText: "",
          statusKind: "ready"
        });
      }
    }, this);
  },

  loadBitmapImage(tempFilePath, transform) {
    const image = this.canvasNode && this.canvasNode.createImage
      ? this.canvasNode.createImage()
      : null;

    if (!image) {
      this.bitmapBuildInProgress = false;
      this.setData({
        statusText: "",
        statusKind: "ready"
      });
      return;
    }

    image.onload = () => {
      this.bitmapImage = image;
      this.bitmapTransform = transform;
      this.bitmapBuildInProgress = false;
      this.renderCachedBitmap();
      this.setData({
        statusText: "",
        statusKind: "ready"
      });

      if (this.pendingBitmapBuild) {
        this.rebuildBitmapCache();
      }
    };
    image.onerror = () => {
      this.bitmapBuildInProgress = false;
      this.setData({
        statusText: "",
        statusKind: "ready"
      });
    };
    image.src = tempFilePath;
  },

  renderCachedBitmap() {
    if (!this.bitmapImage || !this.bitmapTransform || !this.canvasContext) {
      this.drawVectorMap();
      return;
    }

    const current = this.viewTransform;
    const cached = this.bitmapTransform;
    const scaleRatio = current.scale / cached.scale;
    const drawX = current.translateX - cached.translateX * scaleRatio;
    const drawY = current.translateY - cached.translateY * scaleRatio;

    this.clearCanvas();
    this.canvasContext.drawImage(
      this.bitmapImage,
      drawX,
      drawY,
      this.canvasWidth * scaleRatio,
      this.canvasHeight * scaleRatio
    );
  },

  copyViewTransform() {
    return {
      scale: this.viewTransform.scale,
      translateX: this.viewTransform.translateX,
      translateY: this.viewTransform.translateY
    };
  },

  resetMapView() {
    this.viewTransform = this.getInitialViewTransform();
    this.touchState = null;
    this.bitmapImage = null;
    this.bitmapTransform = null;
    this.pendingBitmapBuild = false;
  },

  getInitialViewTransform() {
    const centerLocation = CITY_LOCATIONS[INITIAL_MAP_CENTER_CITY];
    const centerPoint = centerLocation
      ? this.projectWebMercatorPoint([centerLocation.lng, centerLocation.lat])
      : null;
    const basePoint = centerPoint ? this.getBaseCanvasPoint(centerPoint) : null;

    if (basePoint && this.canvasWidth && this.canvasHeight) {
      return {
        scale: INITIAL_MAP_ZOOM,
        translateX: this.canvasWidth / 2 - basePoint.x * INITIAL_MAP_ZOOM,
        translateY: this.canvasHeight / 2 - basePoint.y * INITIAL_MAP_ZOOM
      };
    }

    return {
      scale: INITIAL_MAP_ZOOM,
      translateX: this.canvasWidth ? this.canvasWidth * (1 - INITIAL_MAP_ZOOM) / 2 : 0,
      translateY: this.canvasHeight ? this.canvasHeight * (1 - INITIAL_MAP_ZOOM) / 2 : 0
    };
  },

  getBaseCanvasPoint(point) {
    if (!point || !this.mapBounds || !this.canvasWidth || !this.canvasHeight) return null;

    const baseTransform = this.mapBaseTransform || this.getMapBaseTransform();
    if (!baseTransform) return null;

    return {
      x: baseTransform.padding + (point.x - this.mapBounds.minX) * baseTransform.scale + baseTransform.offsetX,
      y: baseTransform.padding + (this.mapBounds.maxY - point.y) * baseTransform.scale + baseTransform.offsetY
    };
  },

  getMapBaseTransform() {
    if (!this.mapBounds || !this.canvasWidth || !this.canvasHeight) return null;

    const xSpan = this.mapBounds.maxX - this.mapBounds.minX;
    const ySpan = this.mapBounds.maxY - this.mapBounds.minY;
    const padding = Math.max(8, Math.min(this.canvasWidth, this.canvasHeight) * 0.03);
    const drawableWidth = Math.max(1, this.canvasWidth - padding * 2);
    const drawableHeight = Math.max(1, this.canvasHeight - padding * 2);
    const scale = Math.min(drawableWidth / xSpan, drawableHeight / ySpan);
    const mapWidth = xSpan * scale;
    const mapHeight = ySpan * scale;

    this.mapBaseTransform = {
      padding,
      scale,
      offsetX: (drawableWidth - mapWidth) / 2,
      offsetY: (drawableHeight - mapHeight) / 2
    };
    return this.mapBaseTransform;
  },

  finalizeBitmapInteraction() {
    this.renderCachedBitmap();
    this.rebuildBitmapCache();
  },

  openRecordDialog() {
    const selectedRecord = this.getRecordById(this.data.selectedRecordId);
    if (selectedRecord) {
      this.setData({
        showRecordDialog: true,
        editingRecordId: selectedRecord.id,
        recordCity: selectedRecord.city,
        recordDate: selectedRecord.date ? this.formatDisplayDate(selectedRecord.date) : "",
        recordQuantity: String(selectedRecord.quantity || ""),
        recordRemark: selectedRecord.remark || "",
        recordErrorText: ""
      });
      return;
    }

    this.setData({
      showRecordDialog: true,
      editingRecordId: "",
      recordCity: "",
      recordDate: "",
      recordQuantity: "",
      recordRemark: "",
      recordErrorText: ""
    });
  },

  closeRecordDialog() {
    this.setData({
      showRecordDialog: false,
      editingRecordId: "",
      recordErrorText: ""
    });
  },

  onRecordCityInput(event) {
    this.setData({
      recordCity: event.detail.value || "",
      recordErrorText: ""
    });
  },

  onRecordDateInput(event) {
    this.setData({
      recordDate: event.detail.value || "",
      recordErrorText: ""
    });
  },

  onRecordQuantityInput(event) {
    this.setData({
      recordQuantity: String(event.detail.value || "").replace(/\D/g, ""),
      recordErrorText: ""
    });
  },

  onRecordRemarkInput(event) {
    this.setData({
      recordRemark: event.detail.value || "",
      recordErrorText: ""
    });
  },

  submitRecord() {
    const cityName = this.normalizeCityName(this.data.recordCity);
    const location = CITY_LOCATIONS[cityName];
    const parsedDate = this.parseRecordDate(this.data.recordDate);
    const quantity = parseInt(this.data.recordQuantity, 10);
    const remark = (this.data.recordRemark || "").trim();

    if (!location) {
      this.setRecordError("暂不支持该城市");
      return;
    }

    if (parsedDate.error) {
      this.setRecordError(parsedDate.error);
      return;
    }

    if (!Number.isFinite(quantity) || quantity <= 0) {
      this.setRecordError("请输入有效数量");
      return;
    }

    const recordPatch = {
      city: cityName,
      date: parsedDate.value,
      quantity,
      remark,
      location: Object.assign({}, location, {
        projectedPoint: this.projectWebMercatorPoint([location.lng, location.lat])
      })
    };
    const editingRecord = this.getRecordById(this.data.editingRecordId);

    if (editingRecord) {
      Object.assign(editingRecord, recordPatch);
    } else {
      this.records.push(this.createRecord(recordPatch));
    }

    this.refreshHighlightedProvinceMap();
    this.setData({
      showRecordDialog: false,
      editingRecordId: "",
      recordCity: "",
      recordDate: "",
      recordQuantity: "",
      recordRemark: "",
      recordErrorText: ""
    });
    this.rebuildBitmapCache();
  },

  createRecord(record) {
    const location = record.location || {};
    return {
      id: `record-${Date.now()}-${this.recordIdSeed += 1}`,
      city: record.city,
      date: record.date || "",
      quantity: record.quantity,
      remark: record.remark || "",
      expanded: false,
      location: Object.assign({}, location, {
        projectedPoint: location.projectedPoint || this.projectWebMercatorPoint([location.lng, location.lat])
      })
    };
  },

  getRecordById(recordId) {
    if (!recordId) return null;
    return this.records.find((record) => record && record.id === recordId) || null;
  },

  refreshHighlightedProvinceMap() {
    const nextMap = {};
    this.records.forEach((record) => {
      if (record && record.location && record.location.province) {
        nextMap[record.location.province] = true;
      }
    });
    this.highlightedProvinceMap = nextMap;
  },

  deleteSelectedRecord() {
    const selectedRecordId = this.data.selectedRecordId;
    if (!selectedRecordId) return;

    this.records = this.records.filter((record) => record && record.id !== selectedRecordId);
    this.refreshHighlightedProvinceMap();
    this.setData({
      selectedRecordId: "",
      editingRecordId: "",
      showRecordDialog: false,
      recordErrorText: ""
    });
    this.rebuildBitmapCache();
  },

  normalizeCityName(value) {
    return String(value || "").trim().replace(/\s+/g, "").replace(/市$/, "");
  },

  parseRecordDate(value) {
    const raw = String(value || "").trim();
    if (!raw) return { value: "", error: "" };

    if (!/^\d/.test(raw)) {
      return { value: "", error: "请输入年份" };
    }

    const digitGroups = raw.match(/\d+/g) || [];
    if (!digitGroups.length || digitGroups[0].length < 2) {
      return { value: "", error: "请输入年份" };
    }

    if (/^\d+$/.test(raw)) {
      return this.parseCompactDate(raw);
    }

    if (digitGroups.length === 2 && digitGroups[0].length <= 2 && digitGroups[1].length <= 2) {
      return { value: "", error: "请输入年份" };
    }

    if (digitGroups.length !== 3 || (digitGroups[0].length !== 2 && digitGroups[0].length !== 4)) {
      return { value: "", error: "请输入有效日期" };
    }

    return this.buildRecordDate(
      this.normalizeRecordYear(digitGroups[0]),
      Number(digitGroups[1]),
      Number(digitGroups[2])
    );
  },

  parseCompactDate(raw) {
    const yearLengths = [4, 2];
    const monthLengths = [2, 1];

    for (let yearIndex = 0; yearIndex < yearLengths.length; yearIndex += 1) {
      const yearLength = yearLengths[yearIndex];
      if (raw.length <= yearLength) continue;

      const yearText = raw.slice(0, yearLength);
      const rest = raw.slice(yearLength);
      if (yearText.length !== 2 && yearText.length !== 4) continue;

      for (let monthIndex = 0; monthIndex < monthLengths.length; monthIndex += 1) {
        const monthLength = monthLengths[monthIndex];
        const dayLength = rest.length - monthLength;
        if (dayLength < 1 || dayLength > 2) continue;

        const parsed = this.buildRecordDate(
          this.normalizeRecordYear(yearText),
          Number(rest.slice(0, monthLength)),
          Number(rest.slice(monthLength))
        );
        if (parsed.value) return parsed;
      }
    }

    return { value: "", error: "请输入有效日期" };
  },

  normalizeRecordYear(yearText) {
    return yearText.length === 2 ? 2000 + Number(yearText) : Number(yearText);
  },

  buildRecordDate(year, month, day) {
    const date = new Date(year, month - 1, day);
    if (
      date.getFullYear() !== year
      || date.getMonth() !== month - 1
      || date.getDate() !== day
    ) {
      return { value: "", error: "请输入有效日期" };
    }

    return {
      value: `${String(year).padStart(4, "0")}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`,
      error: ""
    };
  },

  formatDisplayDate(dateValue) {
    return String(dateValue || "").replace(/-/g, "/");
  },

  setRecordError(message) {
    this.setData({ recordErrorText: message });
    wx.showToast({ title: message, icon: "none" });
  },

  noop() {},

  onMapTap(event) {
    if (this.hasDraggedMap) {
      this.hasDraggedMap = false;
      return;
    }

    const point = this.getEventPoint(event);
    if (!point) return;

    const hitRect = this.getHitRecordLabel(point);
    if (!hitRect) {
      if (this.data.selectedRecordId) {
        this.setData({ selectedRecordId: "" });
        this.rebuildBitmapCache();
      }
      return;
    }

    const record = this.getRecordById(hitRect.recordId);
    if (!record) return;

    record.expanded = !record.expanded;
    this.setData({ selectedRecordId: record.id });
    this.rebuildBitmapCache();
  },

  getEventPoint(event) {
    if (event && event.detail && Number.isFinite(event.detail.x) && Number.isFinite(event.detail.y)) {
      return {
        x: event.detail.x,
        y: event.detail.y
      };
    }

    const changedTouches = event && event.changedTouches ? event.changedTouches : [];
    if (changedTouches.length) return this.getTouchPoint(changedTouches[0]);
    return null;
  },

  getHitRecordLabel(point) {
    for (let i = this.labelHitRects.length - 1; i >= 0; i -= 1) {
      const rect = this.labelHitRects[i];
      if (
        point.x >= rect.x
        && point.x <= rect.x + rect.width
        && point.y >= rect.y
        && point.y <= rect.y + rect.height
      ) {
        return rect;
      }
    }

    return null;
  },

  onMapTouchStart(event) {
    if (!this.mapPolygons || !this.mapBounds) return;

    this.hasDraggedMap = false;
    const touches = this.getTouchPoints(event);
    if (touches.length >= 2) {
      const startCenter = this.getTouchCenter(touches[0], touches[1]);
      this.touchState = {
        mode: "pinch",
        startDistance: this.getTouchDistance(touches[0], touches[1]),
        startCenter,
        startScale: this.viewTransform.scale,
        startTranslateX: this.viewTransform.translateX,
        startTranslateY: this.viewTransform.translateY
      };
      return;
    }

    if (touches.length === 1) {
      this.touchState = {
        mode: "pan",
        lastPoint: touches[0]
      };
    }
  },

  onMapTouchMove(event) {
    if (!this.touchState || !this.mapPolygons || !this.mapBounds) return;

    const touches = this.getTouchPoints(event);
    if (touches.length >= 2) {
      this.handlePinchMove(touches[0], touches[1]);
      return;
    }

    if (touches.length === 1) {
      this.handlePanMove(touches[0]);
    }
  },

  onMapTouchEnd(event) {
    const touches = this.getTouchPoints(event);
    if (touches.length === 1) {
      this.touchState = {
        mode: "pan",
        lastPoint: touches[0]
      };
      return;
    }

    this.touchState = null;
    this.finalizeBitmapInteraction();
  },

  handlePanMove(point) {
    if (!this.touchState || this.touchState.mode !== "pan" || !this.touchState.lastPoint) {
      this.touchState = {
        mode: "pan",
        lastPoint: point
      };
      return;
    }

    const lastPoint = this.touchState.lastPoint;
    if (Math.abs(point.x - lastPoint.x) > 2 || Math.abs(point.y - lastPoint.y) > 2) {
      this.hasDraggedMap = true;
    }
    this.viewTransform.translateX += point.x - lastPoint.x;
    this.viewTransform.translateY += point.y - lastPoint.y;
    this.touchState.lastPoint = point;
    this.renderCachedBitmap();
  },

  handlePinchMove(firstTouch, secondTouch) {
    const distance = this.getTouchDistance(firstTouch, secondTouch);
    if (!distance) return;
    this.hasDraggedMap = true;

    if (!this.touchState || this.touchState.mode !== "pinch" || !this.touchState.startDistance) {
      const startCenter = this.getTouchCenter(firstTouch, secondTouch);
      this.touchState = {
        mode: "pinch",
        startDistance: distance,
        startCenter,
        startScale: this.viewTransform.scale,
        startTranslateX: this.viewTransform.translateX,
        startTranslateY: this.viewTransform.translateY
      };
      return;
    }

    const nextScale = this.touchState.startScale * distance / this.touchState.startDistance;
    const scaleRatio = nextScale / this.touchState.startScale;
    const startCenter = this.touchState.startCenter;
    const currentCenter = this.getTouchCenter(firstTouch, secondTouch);

    this.viewTransform.scale = nextScale;
    this.viewTransform.translateX = currentCenter.x
      - (startCenter.x - this.touchState.startTranslateX) * scaleRatio;
    this.viewTransform.translateY = currentCenter.y
      - (startCenter.y - this.touchState.startTranslateY) * scaleRatio;
    this.renderCachedBitmap();
  },

  getTouchPoints(event) {
    const touches = event && event.touches ? event.touches : [];
    return Array.prototype.slice.call(touches)
      .map((touch) => this.getTouchPoint(touch))
      .filter(Boolean);
  },

  getTouchPoint(touch) {
    if (!touch) return null;

    if (Number.isFinite(touch.x) && Number.isFinite(touch.y)) {
      return {
        x: touch.x,
        y: touch.y
      };
    }

    const rect = this.canvasRect || { left: 0, top: 0 };
    const rawX = Number.isFinite(touch.clientX) ? touch.clientX : touch.pageX;
    const rawY = Number.isFinite(touch.clientY) ? touch.clientY : touch.pageY;
    if (!Number.isFinite(rawX) || !Number.isFinite(rawY)) return null;

    return {
      x: rawX - rect.left,
      y: rawY - rect.top
    };
  },

  getTouchCenter(firstTouch, secondTouch) {
    return {
      x: (firstTouch.x + secondTouch.x) / 2,
      y: (firstTouch.y + secondTouch.y) / 2
    };
  },

  getTouchDistance(firstTouch, secondTouch) {
    const dx = firstTouch.x - secondTouch.x;
    const dy = firstTouch.y - secondTouch.y;
    return Math.sqrt(dx * dx + dy * dy);
  },

  showMapError(message) {
    this.setData({
      statusText: message,
      statusKind: "error"
    });
  }
});
