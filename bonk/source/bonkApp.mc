import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Math;
import Toybox.Application;
import Toybox.Application.Properties;

// ── Debug flags — flip for simulator, set both false before a device build ───
//
//   DEBUG_ACTIVE     true  → starts in gesture/high-power mode immediately;
//                            onEnterSleep is a no-op so balls + second dot
//                            stay visible for the whole sim session.
//   DEBUG_LIGHT_MODE true  → forces light mode regardless of the stored
//                            property, without touching Garmin Connect.
const DEBUG_ACTIVE     as Boolean = true;
const DEBUG_LIGHT_MODE as Boolean = false;

const NUM_BALLS       as Number = 18;
const BOUNDARY_MARGIN as Float  = 1.0;
const TAU             as Float  = 6.28318; // 2π — avoids repeating the literal

function randFloat(minVal as Float, maxVal as Float) as Float {
    // Integer modulo then a single multiply is cheaper than two fp divisions.
    return minVal + (maxVal - minVal) * ((Math.rand() % 10000) * 0.0001);
}

// Build the MIP-safe colour palette once at startup and reuse it forever.
//
// FR55 = RGB111 (8 colours, 2 levels per channel).
// Fenix 7 series = RGB222 (64 colours, 4 levels per channel: 0x00/0x55/0xAA/0xFF).
//
// On RGB111 devices the OS snaps every channel to its nearest of {0x00, 0xFF}.
// We exclude the near-white cluster (all channels ≥ 0xAA → rounds to 0xFFFFFF)
// and near-black cluster (all channels ≤ 0x55 → rounds to 0x000000) so no ball
// silently vanishes against the background on any supported device.
function buildBallColors() as Array<Number> {
    var levels = [0x00, 0x55, 0xAA, 0xFF] as Array<Number>;
    var colors = [] as Array<Number>;
    for (var ri = 0; ri < 4; ri++) {
        for (var gi = 0; gi < 4; gi++) {
            for (var bi = 0; bi < 4; bi++) {
                var r = levels[ri] as Number;
                var g = levels[gi] as Number;
                var b = levels[bi] as Number;
                if (!(r >= 0xAA && g >= 0xAA && b >= 0xAA) &&
                    !(r <= 0x55 && g <= 0x55 && b <= 0x55)) {
                    colors.add((r << 16) | (g << 8) | b);
                }
            }
        }
    }
    return colors;
}

// Purely decorative — random size, colour, and position on the screen.
// No velocity, no physics. Placed once on spawn and never moves.
class Ball {
    var x      as Float  = 0.0;
    var y      as Float  = 0.0;
    var radius as Float  = 0.0;
    var color  as Number = 0;

    function initialize(w as Number, h as Number, palette as Array<Number>,
                        isRound as Boolean, cx as Float, cy as Float,
                        sr as Float) {
        var minDim = (w < h ? w : h).toFloat();
        radius = randFloat(0.02, 0.09) * minDim;

        if (isRound) {
            var maxDist = sr - radius;
            if (maxDist < 0.0) { maxDist = 0.0; }

            // Raising a uniform [0,1] to a power < 0.5 biases placement toward
            // the edge (0.5 = area-uniform, lower = more edge-biased).
            var spawnDist  = maxDist * Math.pow(randFloat(0.0, 1.0), 0.35);
            var spawnAngle = randFloat(0.0, TAU);
            x = cx + spawnDist * Math.cos(spawnAngle);
            y = cy + spawnDist * Math.sin(spawnAngle);
        } else {
            var margin = radius + BOUNDARY_MARGIN;
            x = randFloat(margin, w - margin);
            y = randFloat(margin, h - margin);
        }

        color = palette[Math.rand() % palette.size()];
    }

    function draw(dc as Graphics.Dc) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x.toNumber(), y.toNumber(), radius.toNumber());
    }
}

class BounceWatchFaceView extends WatchUi.WatchFace {

    // ── Screen geometry (set once in onLayout, never changes) ──────────────
    private var _width        as Number  = 0;
    private var _height       as Number  = 0;
    private var _isRound      as Boolean = false;
    private var _centerX      as Float   = 0.0;
    private var _centerY      as Float   = 0.0;
    private var _screenRadius as Float   = 0.0;
    private var _dotRadius    as Float   = 0.0;
    private var _orbitRadius  as Float   = 0.0; // pre-computed: screenRadius - dotRadius - margin

    // ── Cached settings & derived draw colours ─────────────────────────────
    // Refreshed only via refreshSettings(), never read from Properties on
    // every frame — avoids repeated hash-map lookups during onUpdate().
    private var _isLightMode as Boolean = false;
    private var _alwaysBalls as Boolean = false;
    private var _bgColor     as Number  = Graphics.COLOR_BLACK;
    private var _timeColor   as Number  = Graphics.COLOR_WHITE;
    private var _dotColor    as Number  = Graphics.COLOR_WHITE;

    // ── Ball state ─────────────────────────────────────────────────────────
    private var _balls      as Array<Ball>   = [] as Array<Ball>;
    private var _ballColors as Array<Number> = [] as Array<Number>;

    // ── Sleep / gesture state ──────────────────────────────────────────────
    // True only in high-power mode (post-gesture / onExitSleep).
    // Controls second-dot visibility and whether onUpdate drives 1Hz redraws.
    private var _isGestureActive as Boolean = false;

    // ── Time-string cache ──────────────────────────────────────────────────
    // Rebuilt only when the minute ticks over; avoids string allocation every
    // second while the second dot is ticking.
    private var _lastMinute       as Number = -1;
    private var _cachedTimeString as String = "";

    function initialize() {
        WatchFace.initialize();
        Math.srand(System.getTimer());
        _ballColors = buildBallColors(); // built once, reused forever
    }

    function onLayout(dc as Graphics.Dc) as Void {
        _width  = dc.getWidth();
        _height = dc.getHeight();

        var dev = System.getDeviceSettings();
        _isRound      = (dev.screenShape == System.SCREEN_SHAPE_ROUND);
        _centerX      = _width  / 2.0;
        _centerY      = _height / 2.0;
        _screenRadius = (_width < _height ? _width : _height) / 2.0;
        _dotRadius    = _screenRadius * 0.05;
        _orbitRadius  = _screenRadius - _dotRadius - BOUNDARY_MARGIN;

        // First settings load — must happen after geometry is ready in case
        // alwaysBalls is on and we need to spawn immediately.
        refreshSettings();

        // Debug: start in gesture/active mode so the simulator shows the full
        // face without needing a wrist-raise.
        if (DEBUG_ACTIVE) {
            _isGestureActive = true;
            spawnBalls();
        }
    }

    // Read and cache all user properties, then recompute any derived state.
    // Called once at startup (via onLayout) and again from bonkApp whenever
    // the user changes a setting — never called from onUpdate.
    function refreshSettings() as Void {
        // DEBUG_LIGHT_MODE overrides the stored property so you can test the
        // light theme in the simulator without touching Garmin Connect.
        var newLight = DEBUG_LIGHT_MODE
            ? true
            : Properties.getValue("isLightMode") as Boolean;
        var newAlwaysBalls = Properties.getValue("alwaysBalls") as Boolean;

        // Only recompute colours if the light/dark setting actually changed.
        if (newLight != _isLightMode) {
            _isLightMode = newLight;
            _bgColor     = _isLightMode ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;
            _timeColor   = _isLightMode ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE;
            // Second dot must always contrast with background to remain visible.
            _dotColor    = _isLightMode ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE;
        }

        var wasAlwaysBalls = _alwaysBalls;
        _alwaysBalls = newAlwaysBalls;

        if (!_isGestureActive) {
            if (_alwaysBalls && !wasAlwaysBalls) {
                // Setting just turned ON while sleeping — spawn balls immediately.
                spawnBalls();
            } else if (!_alwaysBalls && wasAlwaysBalls) {
                // Setting just turned OFF while sleeping — clear balls immediately.
                _balls = [] as Array<Ball>;
            }
        }
        // No change needed while gesture is active: balls are always showing
        // and the next sleep cycle will handle teardown correctly.
    }

    private function spawnBalls() as Void {
        _balls = [] as Array<Ball>;
        for (var i = 0; i < NUM_BALLS; i++) {
            _balls.add(new Ball(_width, _height, _ballColors,
                                _isRound, _centerX, _centerY, _screenRadius));
        }
    }

    // ── Draw ───────────────────────────────────────────────────────────────

    // MIP displays are capped by the OS to 1 full-screen redraw/second in
    // high-power mode; onUpdate() is called automatically at that cadence.
    // In low-power mode it is called only when WatchUi.requestUpdate() fires
    // (e.g. once a minute for the time, or immediately after state changes).
    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(_bgColor, _bgColor);
        dc.clear();

        // _balls is empty when we are sleeping AND alwaysBalls is off,
        // so this loop costs nothing in the common low-power case.
        var n = _balls.size();
        for (var i = 0; i < n; i++) {
            _balls[i].draw(dc);
        }

        drawTime(dc);

        // Second dot is power-hungry (forces 1Hz high-power redraws).
        // Show it only while the gesture / wake is active.
        if (_isGestureActive) {
            drawSecondDot(dc);
        }
    }

    private function drawTime(dc as Graphics.Dc) as Void {
        var ct = System.getClockTime(); // .hour is always 0-23
        if (ct.min != _lastMinute) {
            _lastMinute = ct.min;
            _cachedTimeString = Lang.format("$1$:$2$", [
                ct.hour.format("%02d"),
                ct.min.format("%02d")
            ]);
        }
        dc.setColor(_timeColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_width / 2, _height / 2,
                    Graphics.FONT_NUMBER_HOT, _cachedTimeString,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // Classic clock-hand placement: 0 s points straight up, clockwise.
    private function drawSecondDot(dc as Graphics.Dc) as Void {
        var theta = (System.getClockTime().sec / 60.0) * TAU;
        var dotX  = _centerX + _orbitRadius * Math.sin(theta);
        var dotY  = _centerY - _orbitRadius * Math.cos(theta);
        dc.setColor(_dotColor, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(dotX.toNumber(), dotY.toNumber(), _dotRadius.toNumber());
    }

    // ── Sleep / wake callbacks ─────────────────────────────────────────────

    // High-power mode: gesture detected.
    // Always spawn fresh ball positions on every wake — both modes get a new
    // splash, which is exactly what you want after wrist-down.
    function onExitSleep() as Void {
        _isGestureActive = true;
        spawnBalls();
        WatchUi.requestUpdate();
    }

    // Low-power mode: wrist lowered.
    // Second dot disappears in both modes.
    // Balls: cleared in default mode, kept (at freshly-spawned positions) in
    // always-balls mode — low-power redraw is minute-driven so keeping the
    // array costs only memory, not CPU.
    function onEnterSleep() as Void {
        // Debug: keep gesture state alive so the simulator doesn't blank the
        // face every time onEnterSleep fires.
        if (DEBUG_ACTIVE) { return; }
        _isGestureActive = false;
        if (!_alwaysBalls) {
            _balls = [] as Array<Ball>;
        }
        WatchUi.requestUpdate();
    }
}

// ── Application ────────────────────────────────────────────────────────────

class bonkApp extends Application.AppBase {

    // Keep a direct reference so onSettingsChanged() can push the update
    // without going through WatchUi.getCurrentView() (which can return null
    // and involves an extra cast on a resource-constrained device).
    private var _view as BounceWatchFaceView?;

    function initialize() {
        AppBase.initialize();
    }

    function onSettingsChanged() as Void {
        if (_view != null) {
            (_view as BounceWatchFaceView).refreshSettings();
        }
        WatchUi.requestUpdate();
    }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        _view = new BounceWatchFaceView();
        return [_view as BounceWatchFaceView];
    }
}

function getApp() as bonkApp {
    return Application.getApp() as bonkApp;
}
