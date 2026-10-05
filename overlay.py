"""Floating recording indicator: a slim translucent pill with a live waveform
while recording, and pulsing dots while the models are processing.
Mode is shown by color (violet = dictation, teal = prompt mode).
Pure AppKit via pyobjc."""
import collections
import math

import objc
from AppKit import (
    NSBackingStoreBuffered,
    NSBezierPath,
    NSColor,
    NSPanel,
    NSScreen,
    NSTimer,
    NSView,
    NSWindowStyleMaskBorderless,
    NSWindowStyleMaskNonactivatingPanel,
)

BAR_COUNT = 20
PANEL_W, PANEL_H = 200, 44
DEFAULT_BAR_COLOR = (0.72, 0.62, 0.98)  # soft violet (dictation mode)


class WaveView(NSView):
    def initWithFrame_(self, frame):
        self = objc.super(WaveView, self).initWithFrame_(frame)
        if self is None:
            return None
        self.levels = collections.deque([0.02] * BAR_COUNT, maxlen=BAR_COUNT)
        self.bar_color = DEFAULT_BAR_COLOR
        self.processing = False
        self.phase = 0
        return self

    def drawRect_(self, rect):
        b = self.bounds()
        # translucent dark pill
        NSColor.colorWithCalibratedWhite_alpha_(0.0, 0.72).setFill()
        NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
            b, b.size.height / 2, b.size.height / 2
        ).fill()
        r, g, bl = self.bar_color
        if self.processing:
            # three pulsing dots while STT/LLM are working
            radius, spacing = 4.0, 18.0
            cx = b.size.width / 2 - spacing
            cy = b.size.height / 2
            for i in range(3):
                alpha = 0.30 + 0.60 * (0.5 + 0.5 * math.sin(self.phase * 0.28 - i * 0.9))
                NSColor.colorWithCalibratedRed_green_blue_alpha_(r, g, bl, alpha).setFill()
                NSBezierPath.bezierPathWithOvalInRect_(
                    ((cx + i * spacing - radius, cy - radius), (radius * 2, radius * 2))
                ).fill()
            return
        # live waveform bars
        pad, gap = 20, 3.5
        bw = (b.size.width - 2 * pad - gap * (BAR_COUNT - 1)) / BAR_COUNT
        NSColor.colorWithCalibratedRed_green_blue_alpha_(r, g, bl, 0.95).setFill()
        for i, lv in enumerate(self.levels):
            bh = max(3, min(1.0, lv * 10) * (b.size.height - 16))
            x = pad + i * (bw + gap)
            y = (b.size.height - bh) / 2
            NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
                ((x, y), (bw, bh)), bw / 2, bw / 2
            ).fill()


class Overlay:
    """show()/show_processing()/hide() must be called on the main thread
    (use AppHelper.callAfter)."""

    def __init__(self, level_fn):
        self.level_fn = level_fn
        screen = NSScreen.mainScreen().frame()
        x = (screen.size.width - PANEL_W) / 2
        self.panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
            ((x, 96), (PANEL_W, PANEL_H)),
            NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel,
            NSBackingStoreBuffered,
            False,
        )
        self.panel.setLevel_(25)  # above normal windows (status level)
        self.panel.setOpaque_(False)
        self.panel.setBackgroundColor_(NSColor.clearColor())
        self.panel.setIgnoresMouseEvents_(True)
        self.panel.setCollectionBehavior_(1)  # visible on all Spaces
        self.view = WaveView.alloc().initWithFrame_(((0, 0), (PANEL_W, PANEL_H)))
        self.panel.setContentView_(self.view)
        self._timer = None

    def _tick(self, _timer):
        self.view.levels.append(self.level_fn())
        self.view.phase += 1
        self.view.setNeedsDisplay_(True)

    def _start_timer(self):
        if self._timer is None:
            self._timer = NSTimer.scheduledTimerWithTimeInterval_repeats_block_(
                1 / 30.0, True, self._tick
            )

    def show(self, color=None):
        self.view.bar_color = color or DEFAULT_BAR_COLOR
        self.view.processing = False
        self.view.levels.extend([0.02] * BAR_COUNT)
        self.panel.orderFrontRegardless()
        self._start_timer()

    def show_processing(self):
        """Switch the pill to pulsing dots (keeps the current mode color)."""
        self.view.processing = True
        self.view.phase = 0
        self.panel.orderFrontRegardless()
        self._start_timer()

    def hide(self):
        if self._timer is not None:
            self._timer.invalidate()
            self._timer = None
        self.panel.orderOut_(None)
