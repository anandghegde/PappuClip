// PappuClipRunner.xpc (architecture §9.5): AppleScripts and Services, out of the app's process so
// that one that hangs can be killed without killing the bar. Everything it does is PappuRunnerHost.
import PappuRunnerHost

RunnerListener.run()
