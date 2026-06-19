// Data downloaded from https://geo.datav.aliyun.com/areas_v3/bound/100000_full.json
const chinaGeoJSON = require("../../data/china-100000-full");
const CANVAS_SELECTOR = "#china-map-canvas";
const CANVAS_INIT_MAX_RETRY = 8;
const WEB_MERCATOR_MAX_LAT = 85.05112878;
const MIN_MAP_ZOOM = 1;
const MAX_MAP_ZOOM = 8;

Page({
  data: {
    statusText: "地图加载中",
    statusKind: "loading"
  },

  mapPolygons: null,
  mapBounds: null,
  canvasNode: null,
  canvasContext: null,
  canvasWidth: 0,
  canvasHeight: 0,
  canvasDpr: 1,
  canvasRect: null,
  bitmapImage: null,
  bitmapTransform: null,
  bitmapBuildInProgress: false,
  pendingBitmapBuild: false,
  hasBuiltInitialMap: false,
  resizeTimer: null,
  touchState: null,
  viewTransform: {
    scale: 1,
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
      if (!geometry || !Array.isArray(geometry.coordinates)) return;

      if (geometry.type === "Polygon") {
        this.appendPolygon(polygons, geometry.coordinates);
        return;
      }

      if (geometry.type === "MultiPolygon") {
        geometry.coordinates.forEach((polygon) => {
          this.appendPolygon(polygons, polygon);
        });
      }
    });

    return polygons;
  },

  appendPolygon(polygons, polygon) {
    if (!Array.isArray(polygon)) return;

    const rings = polygon
      .filter((ring) => Array.isArray(ring) && ring.length > 1)
      .map((ring) => ring
        .map((point) => this.projectWebMercatorPoint(point))
        .filter(Boolean))
      .filter((ring) => ring.length > 1);

    if (rings.length) polygons.push(rings);
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
    const viewTransform = this.viewTransform || {};
    const zoom = viewTransform.scale || 1;
    const translateX = viewTransform.translateX || 0;
    const translateY = viewTransform.translateY || 0;

    this.clearCanvas();
    ctx.beginPath();
    polygons.forEach((polygon) => {
      polygon.forEach((ring) => {
        let started = false;
        ring.forEach((point) => {
          if (!point || !Number.isFinite(point.x) || !Number.isFinite(point.y)) return;
          const baseX = padding + (point.x - bounds.minX) * scale + offsetX;
          const baseY = padding + (bounds.maxY - point.y) * scale + offsetY;
          const canvasX = baseX * zoom + translateX;
          const canvasY = baseY * zoom + translateY;

          if (!started) {
            ctx.moveTo(canvasX, canvasY);
            started = true;
            return;
          }

          ctx.lineTo(canvasX, canvasY);
        });

        if (started) ctx.closePath();
      });
    });

    ctx.strokeStyle = "#d1d5db";
    ctx.lineWidth = 1;
    ctx.lineJoin = "round";
    ctx.lineCap = "round";
    ctx.stroke();
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
    this.viewTransform = {
      scale: 1,
      translateX: 0,
      translateY: 0
    };
    this.touchState = null;
    this.bitmapImage = null;
    this.bitmapTransform = null;
    this.pendingBitmapBuild = false;
  },

  finalizeBitmapInteraction() {
    this.renderCachedBitmap();
    this.rebuildBitmapCache();
  },

  onMapTouchStart(event) {
    if (!this.mapPolygons || !this.mapBounds) return;

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
    this.viewTransform.translateX += point.x - lastPoint.x;
    this.viewTransform.translateY += point.y - lastPoint.y;
    this.touchState.lastPoint = point;
    this.renderCachedBitmap();
  },

  handlePinchMove(firstTouch, secondTouch) {
    const distance = this.getTouchDistance(firstTouch, secondTouch);
    if (!distance) return;

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

    const nextScale = this.clampZoom(
      this.touchState.startScale * distance / this.touchState.startDistance
    );
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

  clampZoom(scale) {
    return Math.max(MIN_MAP_ZOOM, Math.min(scale, MAX_MAP_ZOOM));
  },

  showMapError(message) {
    this.setData({
      statusText: message,
      statusKind: "error"
    });
  }
});
