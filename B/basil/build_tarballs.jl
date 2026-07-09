# Note that this script can accept some limited command-line arguments, run
# `julia build_tarballs.jl --help` to see a usage message.
using BinaryBuilder

name = "basil"
version = v"1.8.2"   # upstream calls itself 1.8.2g; the suffix is not semver

# Pinned to the wenrongcao fork: it carries the regular-mesh (NOR) regression
# fix in vsbcon.f/crust.f/basil.F which greg-houseman/basil does not yet have.
sources = [
    GitSource("https://github.com/wenrongcao/basil.git",
              "3133ea91345bf61ac2d3ef29f7d384dd71ee57d1"),
]

script = raw"""
cd ${WORKSPACE}/srcdir/basil

# The repo carries host-compiled artifacts, and its top-level Makefile is
# imake-generated and host-specific (it records the machine it was made on).
# We never invoke imake; we drive the plain hand-written MakeSimple files.
rm -f objs/*.o basilsrc/*.o basilsrc/*.mod sybilsrc/*.o xpoly/*.o
mkdir -p objs bin

# Every Fortran source that is actually built compiles clean under strict
# gfortran >= 10, so -std=legacy is belt-and-braces only.
#
# Do NOT add -fallow-argument-mismatch: BinaryBuilder's default compiler for
# libgfortran5 is GCC 8.1, and that option did not exist before GCC 10.  It
# would fail the build with "unrecognized command line option" nearly everywhere.
#
# -DGFORTRAN is consumed by the preprocessed basil.F and is silently accepted
# by the plain .f compiles that share FFLAGS.
FFLAGS="-O2 -std=legacy"
CFLAGS="-O2"

if [[ "${target}" == *-linux-gnu* ]]; then
    # Enables triangle.c's x87 FPU precision clamp.  fpu_control.h is glibc-only,
    # hence not on musl / macOS / FreeBSD.
    CFLAGS="${CFLAGS} -DLINUX"
fi

# basilsrc/MakeSimple hardcodes `-lstdc++`, which is correct only on Linux.  On
# Darwin and FreeBSD the C++ toolchain is clang with libc++; since we also compile
# polyutils.cc with ${CXX} (= clang++ there), linking against libstdc++ would be a
# toolchain mismatch even if the library happened to resolve.
if [[ "${target}" == *-apple-darwin* ]] || [[ "${target}" == *freebsd* ]]; then
    CXXLIB="-lc++"
else
    CXXLIB="-lstdc++"
fi

# 1. The FEM solver: F77 + C + one C++ file (polyutils.cc).  MakeSimple's `CPP`
#    variable is what compiles the .cc file and defaults to `gcc` -- override it
#    to the real C++ compiler.  MakeSimple already places $(LDFLAGS) *after* the
#    objects in the link line, which is what the C++ runtime needs.
make -C basilsrc -f MakeSimple -j${nproc} \
    FOR="${FC}" CC="${CC}" CPP="${CXX}" \
    FFLAGS="${FFLAGS} -DGFORTRAN" CFLAGS="${CFLAGS}" LDFLAGS="${CXXLIB}"

# 2. PostScript post-processor only.  The default `all` target would also build
#    the Motif/X11 GUI `sybil`, which we do not ship.  Naming the target
#    explicitly keeps X out entirely (its sources are #ifdef XSYB-guarded).
make -C sybilsrc -f MakeSimple -j${nproc} \
    FOR="${FC}" CC="${CC}" FFLAGS="${FFLAGS}" CFLAGS="${CFLAGS}" \
    ../bin/sybilps

# 3. Mesh/input helper tools (pure Fortran, one file each).
make -C xpoly -f MakeSimple -j${nproc} FOR="${FC}" FFLAGS="${FFLAGS}"

for exe in basil sybilps xpoly polyfix selvect mdcomp basinv circles corotate; do
    install -Dvm755 "bin/${exe}" "${bindir}/${exe}"
done

install_license LICENSE
"""

# basil drives relative cwd paths (FD.sols/, FD.out/) and writes gfortran
# unformatted sequential files.  Windows is untested upstream and is deferred.
platforms = supported_platforms()
filter!(!Sys.iswindows, platforms)
# basil links libgfortran, and polyutils.cc leaves std::string values in the
# `basil` binary (the audit flags this), so both ABI tags must be expanded.
# Neither adds build jobs on current BinaryBuilder: with old_abis=false these
# emit only libgfortran5 and cxx11 respectively.
platforms = expand_gfortran_versions(platforms)
platforms = expand_cxxstring_abis(platforms)

products = [
    ExecutableProduct("basil",    :basil),
    ExecutableProduct("sybilps",  :sybilps),
    ExecutableProduct("xpoly",    :xpoly),
    ExecutableProduct("polyfix",  :polyfix),
    ExecutableProduct("selvect",  :selvect),
    ExecutableProduct("mdcomp",   :mdcomp),
    ExecutableProduct("basinv",   :basinv),
    ExecutableProduct("circles",  :circles),
    ExecutableProduct("corotate", :corotate),
]

# provides libgfortran, libquadmath, libgcc_s, libstdc++
dependencies = [
    Dependency("CompilerSupportLibraries_jll"),
]

build_tarballs(ARGS, name, version, sources, script, platforms, products,
               dependencies; julia_compat="1.6")
