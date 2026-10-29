import java.nio.file.*;
import org.squiddev.cobalt.*;
import org.squiddev.cobalt.compiler.*;
import org.squiddev.cobalt.lib.*;
public class CobaltHarness {
  public static void main(String[] args) throws Exception {
    LuaState state = new LuaState();
    CoreLibraries.debugGlobals(state);
    var chunk = LoadState.load(state, Files.newInputStream(Path.of(args[0])), "@harness.lua", state.globals());
    System.out.println(LuaThread.runMain(state, chunk));
  }
}
