import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Math;
import Toybox.Application;
import Toybox.Application.Properties;

const NUM_BALLS       as Number = 18;
const BOUNDARY_MARGIN as Float  = 1.0;
const TAU             as Float  = 6.28318; // 2π — avoids repeating the literal

// Ball size range, as a fraction of the screen's shorter dimension.
// Bumped up one increment (+0.01 each bound) from the original 0.02/0.09.
const BALL_MIN_SIZE_FRACTION as Float = 0.03;
const BALL_MAX_SIZE_FRACTION as Float = 0.10;

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
// No velocity, no physics. Placed once on spawn/re-spawn and never moves.
//
// xi / yi / ri are integer-cached versions of the geometry so that draw()
// pays zero Float→Number conversion cost per frame (balls never move so
// the conversion only needs to happen once, inside reinitialize()).
class Ball {
    var xi    as Number = 0;
    var yi    as Number = 0;
    var ri    as Number = 0;
    var color as Number = 0;

    // Default constructor — fields stay at zero until reinitialize() is called.
    // Invoked once per slot at app startup; no screen geometry needed here.
    function initialize() {}

    // Seed or re-seed this ball with fresh random geometry and colour.
    // Called on every wrist-raise (and once on first layout).
    // Accepts paletteSize as a pre-computed argument so palette.size() is
    // not called 18 times inside the spawn loop.
    function reinitialize(w as Number, h as Number,
                          palette as Array<Number>, paletteSize as Number,
                          isRound as Boolean,
                          cx as Float, cy as Float, sr as Float) as Void {
        var minDim  = (w < h ? w : h).toFloat();
        var fRadius = randFloat(BALL_MIN_SIZE_FRACTION, BALL_MAX_SIZE_FRACTION) * minDim;

        var fx;
        var fy;
        if (isRound) {
            var maxDist = sr - fRadius;
            if (maxDist < 0.0) { maxDist = 0.0; }

            // Raising a uniform [0,1] to a power < 0.5 biases placement toward
            // the edge (0.5 = area-uniform, lower = more edge-biased).
            var spawnDist  = maxDist * Math.pow(randFloat(0.0, 1.0), 0.35);
            var spawnAngle = randFloat(0.0, TAU);
            fx = cx + spawnDist * Math.cos(spawnAngle);
            fy = cy + spawnDist * Math.sin(spawnAngle);
        } else {
            var margin = fRadius + BOUNDARY_MARGIN;
            fx = randFloat(margin, (w - margin).toFloat());
            fy = randFloat(margin, (h - margin).toFloat());
        }

        // Convert to integers once here; draw() uses them directly with no
        // per-frame conversion cost.
        xi    = fx.toNumber();
        yi    = fy.toNumber();
        ri    = fRadius.toNumber();
        color = palette[Math.rand() % paletteSize];
    }

    function draw(dc as Graphics.Dc) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(xi, yi, ri);
    }
}

class BounceWatchFaceView extends WatchUi.WatchFace {

    // ── Screen geometry (set once in onLayout, never changes) ──────────────
    private var _width        as Number  = 0;
    private var _height       as Number  = 0;
    private var _isRound      as Boolean = false;
    private var _centerX      as Float   = 0.0;
    private var _centerY      as Float   = 0.0;
    private var _centerXi     as Number  = 0;   // integer cache — used in drawText every frame
    private var _centerYi     as Number  = 0;   // integer cache — used in drawText every frame
    private var _screenRadius as Float   = 0.0;

    // ── Cached settings & derived draw colours ─────────────────────────────
    // Refreshed only via refreshSettings(), never read from Properties on
    // every frame — avoids repeated hash-map lookups during onUpdate().
    private var _isLightMode as Boolean = false;
    private var _alwaysBalls as Boolean = false;
    private var _bgColor     as Number  = Graphics.COLOR_BLACK;
    private var _timeColor   as Number  = Graphics.COLOR_WHITE;

    // ── Ball state ─────────────────────────────────────────────────────────
    // _balls is pre-allocated once in initialize() and reused forever —
    // no heap allocation or GC pressure on every wrist-raise.
    // _ballCount controls rendering: 0 = hidden, NUM_BALLS = fully visible.
    private var _balls           as Array<Ball>   = [] as Array<Ball>;
    private var _ballCount       as Number        = 0;
    private var _ballColors      as Array<Number> = [] as Array<Number>;
    private var _lastSpawnMinute as Number        = -1;

    // ── Sleep / gesture state ──────────────────────────────────────────────
    // True only in high-power mode (post-gesture / onExitSleep).
    // Controls whether the low-power ball-hide logic applies.
    private var _isGestureActive as Boolean = false;

    // ── Time-string cache ──────────────────────────────────────────────────
    // Rebuilt only when the minute ticks over; avoids string allocation every
    // redraw.
    private var _lastMinute       as Number = -1;
    private var _cachedTimeString as String = "";

    function initialize() {
        WatchFace.initialize();
        Math.srand(System.getTimer());
        _ballColors = buildBallColors(); // built once, reused forever

        // Pre-allocate Ball objects so spawnBalls() can reinitialize them
        // in-place rather than allocating a fresh array on every wrist-raise.
        // Screen geometry isn't available yet; reinitialize() is called later
        // from spawnBalls() after onLayout has run.
        for (var i = 0; i < NUM_BALLS; i++) {
            _balls.add(new Ball());
        }
    }

    function onLayout(dc as Graphics.Dc) as Void {
        _width  = dc.getWidth();
        _height = dc.getHeight();

        var dev = System.getDeviceSettings();
        _isRound      = (dev.screenShape == System.SCREEN_SHAPE_ROUND);
        _centerX      = _width  / 2.0;
        _centerY      = _height / 2.0;
        _centerXi     = _centerX.toNumber(); // cached — avoids division every frame
        _centerYi     = _centerY.toNumber(); // cached — avoids division every frame
        _screenRadius = (_width < _height ? _width : _height) / 2.0;

        // First settings load — must happen after geometry is ready in case
        // alwaysBalls is on and we need to spawn immediately.
        refreshSettings();
    }

    // Read and cache all user properties, then recompute any derived state.
    // Called once at startup (via onLayout) and again from bonkApp whenever
    // the user changes a setting — never called from onUpdate.
    function refreshSettings() as Void {
        var rawLight = Properties.getValue("isLightMode");
        var newLight = (rawLight != null) ? (rawLight as Boolean) : false;

        var rawAlwaysBalls = Properties.getValue("alwaysBalls");
        var newAlwaysBalls = (rawAlwaysBalls != null) ? (rawAlwaysBalls as Boolean) : false;

        // Only recompute colours if the light/dark setting actually changed.
        if (newLight != _isLightMode) {
            _isLightMode = newLight;
            _bgColor     = _isLightMode ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;
            _timeColor   = _isLightMode ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE;
        }

        var wasAlwaysBalls = _alwaysBalls;
        _alwaysBalls = newAlwaysBalls;

        if (!_isGestureActive) {
            if (_alwaysBalls && !wasAlwaysBalls) {
                // Setting just turned ON while sleeping — spawn balls immediately.
                spawnBalls();
            } else if (!_alwaysBalls && wasAlwaysBalls) {
                // Setting just turned OFF while sleeping — hide balls immediately.
                // The array stays allocated; _ballCount = 0 makes the draw loop free.
                _ballCount = 0;
            }
        }
        // No change needed while gesture is active: balls are always showing
        // and the next sleep cycle will handle teardown correctly.
    }

    private function spawnBalls() as Void {
        _lastSpawnMinute = System.getClockTime().min;

        // Reuse the pre-allocated Ball objects — no heap allocation, no GC.
        // Palette size is cached once here rather than inside each reinitialize().
        var paletteSize = _ballColors.size();
        for (var i = 0; i < NUM_BALLS; i++) {
            _balls[i].reinitialize(_width, _height, _ballColors, paletteSize,
                                   _isRound, _centerX, _centerY, _screenRadius);
        }
        _ballCount = NUM_BALLS;
    }

    // ── Draw ───────────────────────────────────────────────────────────────

    // MIP displays are capped by the OS to 1 full-screen redraw/second in
    // high-power mode; onUpdate() is called automatically at that cadence
    // regardless of what the app draws. In low-power mode it is called only
    // when WatchUi.requestUpdate() fires (e.g. once a minute for the time,
    // or immediately after a state change).
    function onUpdate(dc as Graphics.Dc) as Void {
        var ct = System.getClockTime();

        if (ct.min != _lastMinute) {
            _lastMinute = ct.min;

            var hour = ct.hour;
            var is24Hour = System.getDeviceSettings().is24Hour;

            if (!is24Hour) {
                hour = hour % 12;
                if (hour == 0) { hour = 12; }
            }

            _cachedTimeString = Lang.format("$1$:$2$", [
                is24Hour ? hour.format("%02d") : hour.format("%d"),
                ct.min.format("%02d")
            ]);

            if (_alwaysBalls && _lastSpawnMinute != ct.min) {
                spawnBalls();
            }
        }

        dc.setColor(_bgColor, _bgColor);
        dc.clear();

        // _ballCount is 0 when sleeping AND alwaysBalls is off,
        // so this loop costs nothing in the common low-power case.
        for (var i = 0; i < _ballCount; i++) {
            _balls[i].draw(dc);
        }

        drawTime(dc);
    }

    private function drawTime(dc as Graphics.Dc) as Void {
        dc.setColor(_timeColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_centerXi, _centerYi,
                    Graphics.FONT_NUMBER_HOT, _cachedTimeString,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
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
    // Balls: hidden (_ballCount = 0) in default mode, kept visible in
    // alwaysBalls mode — low-power redraw is minute-driven so keeping the
    // array alive costs only memory, not CPU.
    function onEnterSleep() as Void {
        _isGestureActive = false;
        if (!_alwaysBalls) {
            _ballCount = 0;
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

