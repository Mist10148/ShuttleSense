"""Recorded Watch video sampling and export, shared with selected-player practice."""

from shuttlesense.io import FrameReader


def open_watch_video(source, config):
    live = config.get("live") or {}
    return FrameReader(
        source,
        target_height=int(live.get("target_height", 720)),
        max_fps=float(live.get("max_fps", 30)),
    )


def render_watch_video(record, reader, output, *, overlays, config, progress):
    from shuttlesense.render import render_video

    return render_video(
        record,
        reader.frames(0, len(record.frames)),
        output,
        overlays=overlays,
        config=config,
        progress=progress,
    )
