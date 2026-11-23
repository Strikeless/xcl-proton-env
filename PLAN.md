# xcl-proton-env project plan
This document describes goals and non-goals for this project, and a rough plan on how goals should be achieved.
This document is meant to be read by LLMs implementing the project.

## Goals
The goal of this project is to create simple scripts assisting in setting up and using [XCL](https://github.com/ivall/xcl) (an Xbox series X|S to Windows compatibility layer, comparable to Wine) on Linux via the use of Wine/Proton.

A rough vision of achieving this goal would be to have three shell scripts (target Bash and Zsh):
- `prefix-init.sh`:
    - Creates a new wineprefix (prompt user for a Wine/Proton binary to use) at a user specified directory (default to `./pfx`)
    - Copies XCL from the git submodule `./xcl` to the wineprefix
    - Installs any components to the wineprefix required for building XCL and builds XCL
    - Installs any components to the wineprefix required to successfully run XCL in a real-world use case
- `xcl-run-unsandboxed.sh`:
    - Runs XCL within a wineprefix (previously initialized by `prefix-init.sh`), with a given game directory (containing Xbox game files for XCL to run)
- `xcl-run.sh`:
    - Wraps `xcl-run-unsandboxed.sh` in a tight but functional security sandbox using Bubblewrap:
        - Network access MUST be forbidden
        - File system access MUST NOT be granted to any unnecessary directories (`/home`, etc)
        - File system access to necessary directories such as system libraries (`/lib`, `/lib64`, etc) MUST be restricted to R+X only (write access is strictly forbidden)
        - File system access to the game directory SHOULD be restricted to read-only, unless XCL requires writability or executability
        - Graphics acceleration must be possible, open up device access as necessary

## Non-goals
Project goals do NOT include:
- Fixing problems in XCL; Any issues stemming from XCL itself should be aided in a later session. If you are an agent, tell the user about these problems and let them act accordingly, but do not get tangled in those issues yourself.
- Aiding the use of illegally obtained game files; Users must provide their own file dumps if necessary from legally owned sources.

