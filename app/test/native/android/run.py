#!/usr/bin/env python3
import argparse
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


def version_key(path):
    return tuple(int(part) for part in re.findall(r"\d+", path.parent.parent.name))


def main():
    parser = argparse.ArgumentParser(
        description="Run production Android Kotlin with JVM stubs, then compile against cached Android/Flutter APIs; no downloads or Gradle."
    )
    parser.parse_args()
    tests = Path(__file__).resolve().parent
    app = tests.parents[2]
    production = sorted((app / "android/app/src/main/kotlin").rglob("*.kt"))
    cache = Path(os.environ.get("GRADLE_USER_HOME", Path.home() / ".gradle")) / "caches/modules-2/files-2.1"

    def artifact(group, name, version="*"):
        files = list((cache / group / name).glob(f"{version}/*/{name}-*.jar"))
        files = [p for p in files if not p.name.endswith(("-sources.jar", "-javadoc.jar"))]
        if not files:
            raise RuntimeError(f"Missing cached {group}:{name}:{version} under {cache}; no download attempted")
        return max(files, key=version_key)

    def first_cached(group, *names):
        for name in names:
            try:
                return artifact(group, name)
            except RuntimeError:
                continue
        raise RuntimeError(f"Missing cached {group} artifact from {names}; no download attempted")

    compiler = artifact("org.jetbrains.kotlin", "kotlin-compiler-embeddable", os.environ.get("KOTLIN_VERSION", "*"))
    version = compiler.parent.parent.name
    stdlib = artifact("org.jetbrains.kotlin", "kotlin-stdlib", version)
    compiler_jars = [compiler, stdlib, artifact("org.jetbrains", "annotations")]
    pom = compiler.with_suffix(".pom")
    if not pom.is_file():
        poms = list((cache / "org.jetbrains.kotlin/kotlin-compiler-embeddable" / version).glob("*/*.pom"))
        if not poms:
            raise RuntimeError("Missing cached Kotlin compiler dependency metadata; no download attempted")
        pom = poms[0]
    namespace = {"m": "http://maven.apache.org/POM/4.0.0"}
    for dependency in ET.parse(pom).findall("m:dependencies/m:dependency", namespace):
        if dependency.findtext("m:scope", "compile", namespace) not in ("compile", "runtime"):
            continue
        compiler_jars.append(artifact(
            dependency.findtext("m:groupId", namespaces=namespace),
            dependency.findtext("m:artifactId", namespaces=namespace),
            dependency.findtext("m:version", namespaces=namespace),
        ))
    compiler_jars = list(dict.fromkeys(compiler_jars))
    output = Path(tempfile.mkdtemp(prefix="easytimer-android-native-"))
    runtime = output / "runtime"
    runtime.mkdir()
    java = os.environ.get("JAVA", "java")

    def run(command):
        command = [str(item) for item in command]
        rendered = shlex.join(command)
        print(rendered, flush=True)
        with (output / "commands.txt").open("a") as log:
            log.write(rendered + "\n")
        with (output / "results.txt").open("a") as log:
            with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) as process:
                for line in process.stdout:
                    print(line, end="", flush=True)
                    log.write(line)
                if process.wait() != 0:
                    raise RuntimeError(f"Command failed; see {output / 'results.txt'}")

    def compile_kotlin(sources, classpath, target):
        run([
            java, "-cp", os.pathsep.join(map(str, compiler_jars)),
            "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler", "-no-stdlib", "-no-reflect",
            "-jvm-target", "17", "-Werror", "-classpath", os.pathsep.join(map(str, classpath)),
            "-d", target, *sources,
        ])

    print(f"Artifacts: {output}", flush=True)
    compile_kotlin(production + sorted(tests.rglob("*.kt")), [stdlib], output / "probes.jar")
    run([java, f"-Djava.io.tmpdir={runtime}", "-cp", f"{output / 'probes.jar'}{os.pathsep}{stdlib}",
         "one.jiri.easytimer.NativePlaybackProbeKt"])

    android = os.environ.get("ANDROID_JAR")
    if android:
        android_jar = Path(android)
    else:
        sdk = Path(os.environ.get("ANDROID_SDK_ROOT", os.environ.get("ANDROID_HOME", Path.home() / "Android/Sdk")))
        jars = list((sdk / "platforms").glob("android-*/android.jar"))
        if not jars:
            raise RuntimeError("Set ANDROID_JAR to an installed android.jar; no SDK download attempted")
        android_jar = max(jars, key=lambda p: tuple(int(n) for n in re.findall(r"\d+", p.parent.name)))
    flutter = Path(os.environ["FLUTTER_EMBEDDING_JAR"]) if "FLUTTER_EMBEDDING_JAR" in os.environ else first_cached(
        "io.flutter", "flutter_embedding_debug", "flutter_embedding_release", "flutter_embedding_profile")
    classpath = [stdlib, android_jar, flutter,
                 first_cached("androidx.lifecycle", "lifecycle-common-jvm", "lifecycle-common"),
                 first_cached("androidx.annotation", "annotation-jvm", "annotation")]
    compile_kotlin(production, classpath, output / "android-native.jar")
    print(f"PASS: production Kotlin {version} compilation against installed Android/Flutter APIs (JVM 17, warnings as errors)")
    print(f"Artifacts and exact commands: {output}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
