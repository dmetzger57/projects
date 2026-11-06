"""projkit: project folder model, CLI and UI."""
__version__ = "0.2.0"


def _allow_icloud_downloads() -> None:
    """Let this process download iCloud files that macOS has evicted ("dataless").

    Processes started by launchd (e.g. the `proj serve` LaunchAgent) are denied
    this by default, and every read of an evicted README or folder then fails
    with EDEADLK ("Resource deadlock avoided"), no matter how often it's retried.
    """
    import sys

    if sys.platform != "darwin":
        return
    try:
        import ctypes

        libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        # setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS,
        #                IOPOL_MATERIALIZE_DATALESS_FILES_ON)
        libc.setiopolicy_np(3, 0, 2)
    except Exception:
        pass


_allow_icloud_downloads()
