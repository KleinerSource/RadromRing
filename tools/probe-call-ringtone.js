"use strict";

if (!ObjC.available) {
  send({ event: "probe-error", reason: "Objective-C runtime is unavailable" });
} else {
  const processName = Process.name;
  const attached = new Set();

  function valueFor(object, selector) {
    try {
      const sel = ObjC.selector(selector);
      if (!object.respondsToSelector_(sel)) return null;
      const value = object[selector]();
      return value === null || value === undefined ? null : value.toString();
    } catch (_) {
      return null;
    }
  }

  function callSummary(pointer) {
    if (pointer.isNull()) return null;

    try {
      const call = new ObjC.Object(pointer);
      const provider = call.respondsToSelector_(ObjC.selector("provider")) ? call.provider() : null;
      const identifiers = valueFor(call, "contactIdentifiers");
      return {
        incoming: valueFor(call, "isIncoming"),
        voip: valueFor(call, "isVoIPCall"),
        telephonyProvider: valueFor(provider, "isTelephonyProvider"),
        hasContactIdentifier: valueFor(call, "contactIdentifier") !== null,
        hasContactIdentifiers: identifiers !== null && identifiers !== "()",
        callStatus: valueFor(call, "callStatus"),
      };
    } catch (error) {
      return { readError: String(error) };
    }
  }

  function descriptorSummary(pointer) {
    if (pointer.isNull()) return null;

    try {
      const descriptor = new ObjC.Object(pointer);
      return {
        soundType: valueFor(descriptor, "soundType"),
        sound: valueFor(descriptor, "sound"),
        iterations: valueFor(descriptor, "iterations"),
        pauseDuration: valueFor(descriptor, "pauseDuration"),
      };
    } catch (error) {
      return { readError: String(error) };
    }
  }

  function attachInstanceMethod(className, selector, callback) {
    const key = `${className} ${selector}`;
    if (attached.has(key)) return false;

    const cls = ObjC.classes[className];
    if (!cls) return false;

    const method = cls[`- ${selector}`];
    if (!method || method.implementation.isNull()) return false;

    Interceptor.attach(method.implementation, {
      onEnter(args) {
        try {
          callback(args);
        } catch (error) {
          send({ event: "probe-error", processName, method: key, reason: String(error) });
        }
      },
    });
    attached.add(key);
    return true;
  }

  const loadedModules = Process.enumerateModules()
    .map((module) => module.name)
    .filter((name) => /TelephonyUtilities|ToneLibrary/i.test(name));

  const soundPlayerMethods = [
    "attemptToPlaySoundType:forCall:",
    "attemptToPlaySoundType:forCall:completion:",
    "attemptToPlayDescriptor:",
    "attemptToPlayDescriptor:completion:",
  ];

  const attachedMethods = [];
  for (const selector of soundPlayerMethods.slice(0, 2)) {
    if (attachInstanceMethod("TUCallSoundPlayer", selector, (args) => {
      send({
        event: "call-sound-request",
        processName,
        selector,
        soundType: args[2].toInt32(),
        call: callSummary(args[3]),
      });
    })) attachedMethods.push(`TUCallSoundPlayer ${selector}`);
  }

  for (const selector of soundPlayerMethods.slice(2)) {
    if (attachInstanceMethod("TUCallSoundPlayer", selector, (args) => {
      send({
        event: "call-sound-descriptor",
        processName,
        selector,
        descriptor: descriptorSummary(args[2]),
      });
    })) attachedMethods.push(`TUCallSoundPlayer ${selector}`);
  }

  const descriptorInit = "initWithSoundType:call:";
  if (attachInstanceMethod("TUCallSoundPlayerDescriptor", descriptorInit, (args) => {
    send({
      event: "descriptor-init",
      processName,
      soundType: args[2].toInt32(),
      call: callSummary(args[3]),
    });
  })) attachedMethods.push(`TUCallSoundPlayerDescriptor ${descriptorInit}`);

  const toneManager = ObjC.classes.TLToneManager;
  const toneMethods = toneManager
    ? toneManager.$ownMethods.filter((method) => /tone|ringtone/i.test(method))
    : [];

  send({
    event: "probe-ready",
    processName,
    pid: Process.id,
    loadedModules,
    foundClasses: {
      TUCallSoundPlayer: Boolean(ObjC.classes.TUCallSoundPlayer),
      TUCallSoundPlayerDescriptor: Boolean(ObjC.classes.TUCallSoundPlayerDescriptor),
      TLToneManager: Boolean(toneManager),
    },
    attachedMethods,
    toneManagerMethods: toneMethods,
  });
}
