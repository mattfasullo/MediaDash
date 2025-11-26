#!/bin/bash
# Verify appcast.xml format and version numbers
# Usage: ./verify_appcast.sh

set -e

APPCAST_FILE="appcast.xml"

if [ ! -f "$APPCAST_FILE" ]; then
    echo "❌ Error: $APPCAST_FILE not found"
    exit 1
fi

echo "🔍 Verifying appcast.xml..."
echo ""

ERRORS=0
WARNINGS=0

# Check if file is valid XML
if ! xmllint --noout "$APPCAST_FILE" 2>/dev/null; then
    echo "❌ ERROR: appcast.xml is not valid XML"
    ERRORS=$((ERRORS + 1))
    exit 1
fi

# Extract all items and check sparkle:version
echo "Checking version numbers..."
echo ""

# Use Python to parse and validate
python3 <<PYTHON
import re
import sys
from xml.etree import ElementTree as ET

try:
    tree = ET.parse("$APPCAST_FILE")
    root = tree.getroot()
    
    # Define Sparkle namespace
    sparkle_ns = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
    
    errors = 0
    warnings = 0
    
    # Find all items
    items = root.findall('.//item')
    
    if not items:
        print("❌ ERROR: No items found in appcast")
        sys.exit(1)
    
    print(f"Found {len(items)} version(s) in appcast:")
    print("")
    
    versions = []
    build_numbers = []
    
    for i, item in enumerate(items, 1):
        title_elem = item.find('title')
        title = title_elem.text if title_elem is not None else "Unknown"
        
        enclosure = item.find('enclosure')
        if enclosure is None:
            print(f"❌ ERROR: Item {i} ({title}) has no enclosure")
            errors += 1
            continue
        
        # Get sparkle:version (build number)
        sparkle_version = enclosure.get('{{{sparkle}}}version'.format(sparkle=sparkle_ns['sparkle']))
        if sparkle_version is None:
            # Try without namespace
            sparkle_version = enclosure.get('sparkle:version')
        
        # Get sparkle:shortVersionString (version string)
        short_version = enclosure.get('{{{sparkle}}}shortVersionString'.format(sparkle=sparkle_ns['sparkle']))
        if short_version is None:
            short_version = enclosure.get('sparkle:shortVersionString')
        
        if sparkle_version is None:
            print(f"❌ ERROR: Item {i} ({title}) missing sparkle:version")
            errors += 1
            continue
        
        if short_version is None:
            print(f"⚠️  WARNING: Item {i} ({title}) missing sparkle:shortVersionString")
            warnings += 1
        
        # Check if sparkle:version is numeric
        try:
            build_num = int(sparkle_version)
            build_numbers.append(build_num)
            versions.append((title, short_version or "N/A", build_num))
            
            # Check if it looks like a version string instead of build number
            if '.' in sparkle_version:
                print(f"❌ ERROR: Item {i} ({title}) has sparkle:version=\"{sparkle_version}\" (looks like version string, should be build number)")
                errors += 1
            else:
                print(f"✓ Item {i}: {title}")
                print(f"    Version: {short_version or 'N/A'}")
                print(f"    Build: {build_num}")
        except ValueError:
            print(f"❌ ERROR: Item {i} ({title}) has non-numeric sparkle:version=\"{sparkle_version}\"")
            errors += 1
    
    print("")
    
    # Check version ordering (newest should be first)
    if len(build_numbers) > 1:
        sorted_builds = sorted(build_numbers, reverse=True)
        if build_numbers != sorted_builds:
            print("⚠️  WARNING: Versions are not in descending order (newest first)")
            print(f"   Current order: {build_numbers}")
            print(f"   Should be: {sorted_builds}")
            warnings += 1
    
    # Summary
    print("=" * 50)
    if errors > 0:
        print(f"❌ FAILED: {errors} error(s) found")
        sys.exit(1)
    elif warnings > 0:
        print(f"⚠️  PASSED with {warnings} warning(s)")
        sys.exit(0)
    else:
        print("✅ PASSED: All checks passed")
        sys.exit(0)

except Exception as e:
    print(f"❌ ERROR parsing appcast: {e}")
    sys.exit(1)
PYTHON

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    echo ""
    echo "✅ Appcast verification passed!"
else
    echo ""
    echo "❌ Appcast verification failed!"
    exit 1
fi

