#!/usr/bin/env python3
import sys
import json
import AppKit
import ApplicationServices

def get_ax_attribute(element, attribute):
    err, val = ApplicationServices.AXUIElementCopyAttributeValue(element, attribute, None)
    if err == 0:
        return val
    return None

def get_ax_children(element):
    children = get_ax_attribute(element, ApplicationServices.kAXChildrenAttribute)
    if children:
        return list(children)
    return []

def dump_element(element, depth=0, max_depth=5):
    if depth > max_depth:
        return None
    
    role = get_ax_attribute(element, ApplicationServices.kAXRoleAttribute)
    subrole = get_ax_attribute(element, ApplicationServices.kAXSubroleAttribute)
    title = get_ax_attribute(element, ApplicationServices.kAXTitleAttribute)
    description = get_ax_attribute(element, ApplicationServices.kAXDescriptionAttribute)
    value = get_ax_attribute(element, ApplicationServices.kAXValueAttribute)
    identifier = get_ax_attribute(element, "AXIdentifier")

    node = {
        "role": str(role) if role else None,
        "subrole": str(subrole) if subrole else None,
        "title": str(title) if title else None,
        "description": str(description) if description else None,
        "identifier": str(identifier) if identifier else None,
        "value": str(value)[:80] if value and isinstance(value, str) else None,
        "children": []
    }

    # Filter out empty node info to keep trace clean
    children = get_ax_children(element)
    for c in children:
        c_node = dump_element(c, depth + 1, max_depth)
        if c_node:
            node["children"].append(c_node)
            
    return node

def find_antigravity_pid():
    workspace = AppKit.NSWorkspace.sharedWorkspace()
    for app in workspace.runningApplications():
        if app.bundleIdentifier() == "com.google.antigravity" or "antigravity" in (app.localizedName() or "").lower():
            return app.processIdentifier()
    return None

def main():
    pid = find_antigravity_pid()
    if not pid:
        print("ANTIGRAVITY_PROCESS_NOT_RUNNING")
        sys.exit(1)

    app_ref = ApplicationServices.AXUIElementCreateApplication(pid)
    tree = dump_element(app_ref, depth=0, max_depth=4)
    print(json.dumps(tree, indent=2))

if __name__ == "__main__":
    main()
