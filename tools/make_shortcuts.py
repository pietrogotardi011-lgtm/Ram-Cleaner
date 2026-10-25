import plistlib, uuid, os
BUNDLE = "com.example.powerpilot"
OUT = os.path.join(os.path.dirname(__file__), "..", "Shortcuts")
os.makedirs(OUT, exist_ok=True)

def act(ident, params=None):
    return {"WFWorkflowActionIdentifier": ident, "WFWorkflowActionParameters": params or {}}
def lpm(on): return act("is.workflow.actions.lowpowermode.set", {"OnValue": on})
def bright(v): return act("is.workflow.actions.setbrightness", {"WFBrightness": v})
def bt(on): return act("is.workflow.actions.bluetooth.set", {"OnValue": on})
def wifi(on): return act("is.workflow.actions.wifi.set", {"OnValue": on})
def notify(title, body):
    return act("is.workflow.actions.notification", {
        "WFNotificationActionTitle": title, "WFNotificationActionBody": body, "WFNotificationActionSound": True})
def intent(name):
    return act(f"{BUNDLE}.{name}", {
        "AppIntentDescriptor": {"AppIntentIdentifier": name, "BundleIdentifier": BUNDLE, "Name": "PowerPilot"},
        "UUID": str(uuid.uuid4()).upper()})

CLASSES = ["WFAppStoreAppContentItem","WFArticleContentItem","WFContactContentItem","WFDateContentItem",
 "WFEmailAddressContentItem","WFGenericFileContentItem","WFImageContentItem","WFiTunesProductContentItem",
 "WFLocationContentItem","WFDCMapsLinkContentItem","WFAVAssetContentItem","WFPDFContentItem",
 "WFPhoneNumberContentItem","WFRichTextContentItem","WFSafariWebPageContentItem","WFStringContentItem","WFURLContentItem"]

SHORTCUTS = {
 "PowerPilot Max Battery": (4282601983, 59771, [lpm(True), bright(0.30), bt(False),
     notify("PowerPilot", "Max Battery profile applied")]),
 "PowerPilot Cool Down": (4282601983, 59771, [lpm(True), bright(0.20), bt(False),
     notify("PowerPilot", "Cool Down applied. Remove the case and stop charging.")]),
 "PowerPilot Performance": (4282601983, 59771, [lpm(False), bright(0.70), wifi(True),
     notify("PowerPilot", "Performance profile applied")]),
 "PowerPilot Overnight": (4282601983, 59771, [lpm(True), bright(0.0), bt(False),
     notify("PowerPilot", "Overnight profile applied")]),
 "PowerPilot Normal": (4282601983, 59771, [lpm(False), bright(0.60), bt(True), wifi(True),
     notify("PowerPilot", "Back to normal settings")]),
 "PowerPilot Unplug Alert": (4282601983, 59771, [
     notify("Unplug now", "Battery reached your charge limit. Unplug to reduce wear.")]),
 "PowerPilot Heat Check": (4282601983, 59771, [intent("CheckAndAlertIntent")]),
 "PowerPilot Log": (4282601983, 59771, [intent("LogSnapshotIntent")]),
}

for name, (color, glyph, actions) in SHORTCUTS.items():
    d = {
        "WFWorkflowActions": actions,
        "WFWorkflowClientVersion": "2900.0.1",
        "WFWorkflowClientRelease": "18.0",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowHasShortcutInputVariables": False,
        "WFWorkflowImportQuestions": [],
        "WFWorkflowInputContentItemClasses": CLASSES,
        "WFWorkflowTypes": [],
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": color, "WFWorkflowIconGlyphNumber": glyph},
    }
    with open(os.path.join(OUT, name + ".shortcut"), "wb") as f:
        f.write(plistlib.dumps(d, fmt=plistlib.FMT_BINARY))
    print("wrote", name)
