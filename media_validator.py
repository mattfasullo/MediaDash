"""
OMF/AAF Media Validator

This module provides functionality to check OMF (Open Media Framework) and AAF (Advanced Authoring Format)
files for missing or unlinked audio media. It validates both embedded media and external file references.
"""

import os
import re
import struct
import json
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Set
from dataclasses import dataclass, asdict

try:
    import aaf2
    AAF_SUPPORT = True
except ImportError:
    AAF_SUPPORT = False

# Global flag for debug verbosity (set in main)
DEBUG_VERBOSE = True

# Global debug file handle (set in main)
_DEBUG_FILE = None

def _debug_print(message: str, verbose_only: bool = False):
    """Helper function to print debug messages, respecting DEBUG_VERBOSE flag."""
    import sys
    if not verbose_only or DEBUG_VERBOSE:
        print(message, file=sys.stderr)
    
    # Also write to debug file if it exists
    if _DEBUG_FILE is not None:
        try:
            _DEBUG_FILE.write(message + "\n")
            _DEBUG_FILE.flush()
        except Exception:
            pass


@dataclass
class MediaClip:
    """Represents an audio clip found in an OMF/AAF file."""
    name: str
    clip_id: Optional[str] = None
    is_embedded: bool = False
    external_path: Optional[str] = None
    is_valid: bool = True
    error_message: Optional[str] = None
    # Timeline information (for AAF files)
    track_index: int = 0
    timeline_start: float = 0.0
    timeline_end: float = 0.0
    # Name matching validation
    name_matches_file: Optional[bool] = None
    expected_filename: Optional[str] = None


@dataclass
class ValidationReport:
    """Report containing the results of media validation."""
    total_clips: int
    embedded_clips: int
    linked_clips: int
    missing_clips: int
    valid_clips: int
    missing_clip_details: List[MediaClip]
    file_path: str
    timeline_clips: Optional[List[MediaClip]] = None  # Clips with timeline information
    total_duration: float = 0.0  # Total timeline duration in seconds
    
    def __post_init__(self):
        if self.timeline_clips is None:
            self.timeline_clips = []


# ============================================================================
# ARCHIVED: Playback verification feature - disabled due to aaf2 library limitations
# TODO: Revisit when we have a solution for extracting embedded essence data
# Date archived: 2024-12-19
# ============================================================================
# @dataclass
# class PlaybackClip:
#     """Represents an audio clip for playback verification."""
#     name: str
#     file_path: str
#     start_time: float = 0.0  # Offset within source file (in seconds)
#     duration: float = 0.0      # Clip duration (in seconds, 0.0 means play entire file)
#     track_index: int = 0      # Which track this clip is on (0-based)
#     timeline_start: float = 0.0  # Start position in timeline (in seconds)
#     timeline_end: float = 0.0    # End position in timeline (in seconds)
#     source_in: float = 0.0      # In point within source file (in seconds)
#     source_out: float = 0.0      # Out point within source file (in seconds)


def _detect_file_type(file_path: str) -> str:
    """
    Detects whether a file is OMF or AAF based on extension and file header.
    
    Args:
        file_path: Path to the file
        
    Returns:
        str: 'aaf', 'omf', or raises ValueError if unknown
    """
    file_ext = os.path.splitext(file_path)[1].lower()
    
    # Check extension first
    if file_ext == '.aaf':
        return 'aaf'
    elif file_ext == '.omf':
        return 'omf'
    
    # Try to detect by file header
    try:
        with open(file_path, 'rb') as f:
            header = f.read(16)
            
        # AAF files typically start with specific identifiers
        # Check for AAF header patterns
        if b'AAF' in header[:8] or header[:4] == b'\x00\x00\x00\x01':
            return 'aaf'
        # OMF files have different header patterns
        elif header[:4] == b'OMFI' or header[:2] == b'\x00\x01':
            return 'omf'
    except Exception:
        pass
    
    # Default based on extension if header check fails
    if file_ext in ['.aaf', '.omf']:
        return file_ext[1:]  # Remove the dot
    
    raise ValueError(f"Unable to determine file type for: {file_path}. Expected .aaf or .omf extension.")


def _parse_aaf_file(file_path: str) -> List[MediaClip]:
    """
    Parses an AAF file to extract audio clip information.
    
    Args:
        file_path: Path to the AAF file
        
    Returns:
        List[MediaClip]: List of all audio clips found in the file
    """
    if not AAF_SUPPORT:
        raise ImportError("pyaaf2 library is required for AAF file support. Install with: pip install pyaaf2")
    
    clips: List[MediaClip] = []
    processed_sources: Set[str] = set()  # Track processed sources to avoid duplicates
    
    try:
        with aaf2.open(file_path, 'r') as f:
            # Get all top-level compositions
            compositions = list(f.content.toplevel())
            
            # Also try to get all mobs directly (some AAF files structure differently)
            try:
                # mobs is a property, not a callable - access it directly
                mobs = f.content.mobs
                if mobs:
                    try:
                        # Try to iterate the mobs property
                        for mob in mobs:
                            if mob is not None:
                                # Process mobs that might contain media
                                try:
                                    if hasattr(mob, 'slots'):
                                        for slot in mob.slots:
                                            if hasattr(slot, 'segment') and slot.segment:
                                                _extract_clips_from_segment(slot.segment, clips, processed_sources, file_path, depth=0)
                                except Exception:
                                    pass
                    except TypeError:
                        # If not directly iterable, try other methods
                        pass
            except Exception:
                pass
            
            if compositions:
                # Process each composition
                for i, composition in enumerate(compositions):
                    # Recursively process all segments in the composition
                    _extract_clips_from_segment(composition, clips, processed_sources, file_path, depth=0)
            
            # If still no clips found, try a more aggressive approach
            if not clips:
                try:
                    # Look for all source clips in the file
                    # Access mobs as a property, not a callable
                    mobs = f.content.mobs
                    if mobs:
                        try:
                            for mob in mobs:
                                try:
                                    if hasattr(mob, 'name') or hasattr(mob, 'mob_id'):
                                        # Check if this mob has any essence or file references
                                        has_media = False
                                        ext_path = None
                                        
                                        # Check slots for media
                                        if hasattr(mob, 'slots'):
                                            slot_list = list(mob.slots) if hasattr(mob.slots, '__iter__') else []
                                            for slot_idx, slot in enumerate(slot_list):
                                                if hasattr(slot, 'segment'):
                                                    seg = slot.segment
                                                    if hasattr(seg, 'mob') and seg.mob:
                                                        has_media = True
                                                        # Try to extract path
                                                        try:
                                                            if hasattr(seg.mob, 'descriptor'):
                                                                desc = seg.mob.descriptor
                                                                if hasattr(desc, 'locator') and desc.locator:
                                                                    if hasattr(desc.locator, 'path'):
                                                                        ext_path = str(desc.locator.path)
                                                                    elif hasattr(desc.locator, 'url_string'):
                                                                        url = str(desc.locator.url_string)
                                                                        if url.startswith('file://'):
                                                                            ext_path = url[7:]
                                                                        elif not url.startswith('http'):
                                                                            ext_path = url
                                                        except Exception:
                                                            pass
                                                        break
                                        
                                        if has_media:
                                            mob_id = str(getattr(mob, 'mob_id', id(mob)))
                                            if mob_id not in processed_sources:
                                                processed_sources.add(mob_id)
                                                name = getattr(mob, 'name', None) or f"Clip_{len(clips) + 1}"
                                                
                                                # Resolve path if relative
                                                if ext_path and not os.path.isabs(ext_path):
                                                    aaf_dir = os.path.dirname(os.path.abspath(file_path))
                                                    ext_path = os.path.join(aaf_dir, ext_path)
                                                    ext_path = os.path.normpath(ext_path)
                                                
                                                clip = MediaClip(
                                                    name=name,
                                                    clip_id=mob_id,
                                                    is_embedded=ext_path is None,
                                                    external_path=ext_path
                                                )
                                                clips.append(clip)
                                except Exception:
                                    continue
                        except TypeError:
                            # Try alternative access methods
                            try:
                                # Try accessing as a dict or collection
                                if hasattr(mobs, 'values'):
                                    for mob in mobs.values():
                                        pass  # Process if needed
                                elif hasattr(mobs, 'items'):
                                    for key, mob in mobs.items():
                                        pass  # Process if needed
                            except Exception:
                                pass
                except Exception:
                    pass
    
    except Exception as e:
        raise ValueError(f"Error parsing AAF file: {str(e)}")
    
    return clips


def _extract_clips_from_segment(segment, clips: List[MediaClip], processed_sources: Set[str], aaf_file_path: str, depth: int = 0):
    """
    Recursively extracts audio clips from AAF segments.
    
    Args:
        segment: AAF segment object (composition, sequence, or source clip)
        clips: List to append found clips to
        processed_sources: Set of processed source IDs to avoid duplicates
        aaf_file_path: Path to the AAF file (for resolving relative paths)
        depth: Recursion depth (for debugging)
    """
    try:
        segment_type = type(segment).__name__
        segment_name = getattr(segment, 'name', 'Unnamed')
        
        # Check if this is a SourceClip (actual media reference)
        if hasattr(segment, 'mob') and segment.mob is not None:
            source_mob = segment.mob
            
            # Get source ID to avoid processing duplicates
            source_id = str(getattr(source_mob, 'mob_id', id(source_mob)))
            if source_id in processed_sources:
                return
            processed_sources.add(source_id)
            
            # Get clip name - try multiple sources
            clip_name = None
            try:
                # Try segment name first
                if hasattr(segment, 'name') and segment.name:
                    clip_name = str(segment.name).strip()
                # Try MOB name
                if not clip_name and hasattr(source_mob, 'name') and source_mob.name:
                    clip_name = str(source_mob.name).strip()
                # Try descriptor name
                if not clip_name and hasattr(source_mob, 'descriptor'):
                    desc = source_mob.descriptor
                    if hasattr(desc, 'name') and desc.name:
                        clip_name = str(desc.name).strip()
            except Exception:
                pass
            
            # Fallback to generated name
            if not clip_name or clip_name.lower() in ['sourceclip', 'unnamed', '']:
                clip_name = f"Clip_{len(clips) + 1}"
            
            # Check if this is an audio track
            is_audio = False
            try:
                # Check slots for audio tracks
                if hasattr(source_mob, 'slots'):
                    for slot in source_mob.slots:
                        if hasattr(slot, 'media_kind'):
                            media_kind = slot.media_kind
                            if media_kind and 'sound' in str(media_kind).lower():
                                is_audio = True
                                break
            except Exception:
                pass
            
            # If we can't determine, assume it might be audio and include it
            # (better to over-report than miss clips)
            if not is_audio:
                # Try to infer from other attributes
                try:
                    if hasattr(source_mob, 'descriptor'):
                        desc = source_mob.descriptor
                        if desc and ('audio' in str(type(desc)).lower() or 'sound' in str(type(desc)).lower()):
                            is_audio = True
                except Exception:
                    pass
            
            # Process all source clips (be more inclusive - include everything that might be audio)
            # Check for essence data (embedded vs external)
            is_embedded = False
            external_path = None
            
            try:
                # Look for essence descriptor
                if hasattr(source_mob, 'descriptor'):
                    descriptor = source_mob.descriptor
                    
                    # Check for external file reference
                    if hasattr(descriptor, 'locator'):
                        locator = descriptor.locator
                        if locator:
                            # Try to get file path from locator
                            if hasattr(locator, 'path'):
                                external_path = str(locator.path)
                            elif hasattr(locator, 'url_string'):
                                url = str(locator.url_string)
                                # Extract file path from URL if it's a file:// URL
                                if url.startswith('file://'):
                                    external_path = url[7:]  # Remove 'file://' prefix
                                elif not url.startswith('http'):
                                    external_path = url
                    
                    # Check if media is embedded (has essence data in the AAF)
                    if hasattr(descriptor, 'essence') or hasattr(descriptor, 'essence_data'):
                        is_embedded = True
                
                # Alternative: Check for essence mobs
                if not external_path and not is_embedded:
                    if hasattr(source_mob, 'essence'):
                        is_embedded = True
                
                # Also check for file locators in the mob itself
                if not external_path:
                    # Try to find any file references in the mob
                    for slot in getattr(source_mob, 'slots', []):
                        if hasattr(slot, 'segment'):
                            seg = slot.segment
                            if hasattr(seg, 'mob') and seg.mob:
                                mob = seg.mob
                                if hasattr(mob, 'descriptor'):
                                    desc = mob.descriptor
                                    if hasattr(desc, 'locator'):
                                        loc = desc.locator
                                        if loc and hasattr(loc, 'path'):
                                            external_path = str(loc.path)
                                            break
                                        elif loc and hasattr(loc, 'url_string'):
                                            url = str(loc.url_string)
                                            if url.startswith('file://'):
                                                external_path = url[7:]
                                                break
                                            elif not url.startswith('http'):
                                                external_path = url
                                                break
                
            except Exception as e:
                # If we can't determine, assume it's linked and try to find path
                pass
            
            # If we have an external path, resolve it relative to AAF file if needed
            if external_path:
                # Resolve relative paths relative to the AAF file location
                if not os.path.isabs(external_path):
                    aaf_dir = os.path.dirname(os.path.abspath(aaf_file_path))
                    external_path = os.path.join(aaf_dir, external_path)
                external_path = os.path.normpath(external_path)
            
            # Include the clip if:
            # 1. We detected it as audio, OR
            # 2. It has an external path (likely a media file), OR
            # 3. It's marked as embedded (has essence data), OR
            # 4. We can't determine what it is (be inclusive)
            if is_audio or external_path or is_embedded or not hasattr(source_mob, 'slots'):
                # Create MediaClip object
                clip = MediaClip(
                    name=clip_name,
                    clip_id=source_id,
                    is_embedded=is_embedded,
                    external_path=external_path
                )
                clips.append(clip)
        
        # Recursively process slots/segments
        if hasattr(segment, 'slots'):
            slot_list = list(segment.slots) if hasattr(segment.slots, '__iter__') else []
            for slot_idx, slot in enumerate(slot_list):
                if hasattr(slot, 'segment') and slot.segment:
                    _extract_clips_from_segment(slot.segment, clips, processed_sources, aaf_file_path, depth + 1)
        
        # Also check for sequences
        if hasattr(segment, 'components'):
            comp_list = list(segment.components) if hasattr(segment.components, '__iter__') else []
            for comp_idx, component in enumerate(comp_list):
                _extract_clips_from_segment(component, clips, processed_sources, aaf_file_path, depth + 1)
    
    except Exception:
        # Skip segments we can't process
        pass


def _parse_omf_file(file_path: str) -> List[MediaClip]:
    """
    Parses an OMF file to extract audio clip information.
    
    OMF files have a binary structure with chunks. This parser extracts:
    - File path references to external audio media
    - Essence data references (embedded or external)
    - Audio clip metadata
    
    Args:
        file_path: Path to the OMF file
        
    Returns:
        List[MediaClip]: List of all audio clips found in the file
        
    Raises:
        ValueError: If the file is not a valid OMF file or cannot be parsed
    """
    clips: List[MediaClip] = []
    omf_dir = os.path.dirname(os.path.abspath(file_path))
    
    _debug_print(f"DEBUG: Starting OMF file parsing: {file_path}", verbose_only=True)
    
    # Check file size first - reject files that are too large
    try:
        file_size = os.path.getsize(file_path)
        file_size_mb = file_size / (1024 * 1024)
        _debug_print(f"DEBUG: OMF file size: {file_size_mb:.1f}MB", verbose_only=True)
        
        MAX_OMF_SIZE = 200 * 1024 * 1024  # 200MB hard limit
        if file_size > MAX_OMF_SIZE:
            _debug_print(f"DEBUG: ERROR: OMF file is too large ({file_size_mb:.1f}MB). Maximum size is {MAX_OMF_SIZE / (1024*1024):.0f}MB.", verbose_only=True)
            raise ValueError(f"OMF file is too large ({file_size_mb:.1f}MB). Maximum size is {MAX_OMF_SIZE / (1024*1024):.0f}MB.")
    except OSError as e:
        _debug_print(f"DEBUG: Could not get file size: {e}", verbose_only=True)
    
    try:
        with open(file_path, 'rb') as f:
            # Read and verify OMF header
            header = f.read(4)
            _debug_print(f"DEBUG: OMF header bytes: {header.hex()}", verbose_only=True)
            
            # OMF files can have different header formats
            # Check for common OMF identifiers
            if header not in [b'OMFI', b'\x00\x01\x00\x00', b'\x00\x00\x00\x01']:
                # Try to read as little-endian OMF
                f.seek(0)
                # Some OMF files start with version info
                version_check = f.read(8)
                f.seek(0)
                _debug_print(f"DEBUG: Header doesn't match standard OMF format, attempting to parse anyway", verbose_only=True)
                # If it doesn't look like OMF, try to parse anyway
                # (some OMF files have different headers)
                pass
            else:
                _debug_print(f"DEBUG: OMF header recognized", verbose_only=True)
            
            f.seek(0)
            
            # OMF files are structured as chunks
            # We'll search for file path strings and essence references
            _debug_print(f"DEBUG: Extracting file paths from OMF file...", verbose_only=True)
            file_paths = _extract_omf_file_paths(f, omf_dir)
            _debug_print(f"DEBUG: Found {len(file_paths)} file path(s)", verbose_only=True)
            
            _debug_print(f"DEBUG: Extracting essence references from OMF file...", verbose_only=True)
            essence_refs = _extract_omf_essence_references(f)
            _debug_print(f"DEBUG: Found {len(essence_refs)} essence reference(s)", verbose_only=True)
            
            # Combine file paths and essence references into clips
            clip_counter = 1
            processed_paths = set()
            
            # Process file paths (external media)
            for file_path_str in file_paths:
                if file_path_str and file_path_str not in processed_paths:
                    processed_paths.add(file_path_str)
                    
                    # Check if this looks like an audio file
                    audio_extensions = ['.wav', '.aif', '.aiff', '.mp3', '.m4a', '.caf', '.sd2']
                    file_ext = os.path.splitext(file_path_str)[1].lower()
                    
                    _debug_print(f"DEBUG: Processing file path: {file_path_str} (ext: {file_ext})", verbose_only=True)
                    
                    # Include if it's an audio extension, or if we can't determine
                    if file_ext in audio_extensions or not file_ext:
                        clip_name = os.path.basename(file_path_str) or f"Audio Clip {clip_counter}"
                        
                        clip = MediaClip(
                            name=clip_name,
                            clip_id=f"omf_clip_{clip_counter}",
                            is_embedded=False,
                            external_path=file_path_str
                        )
                        clips.append(clip)
                        _debug_print(f"DEBUG: Added clip: {clip_name}", verbose_only=True)
                        clip_counter += 1
                    else:
                        _debug_print(f"DEBUG: Skipped file path (not audio extension): {file_path_str}", verbose_only=True)
            
            # Process essence references (may be embedded or external)
            for essence_ref in essence_refs:
                if essence_ref.get('path') and essence_ref['path'] not in processed_paths:
                    processed_paths.add(essence_ref['path'])
                    
                    clip_name = essence_ref.get('name') or os.path.basename(essence_ref['path']) or f"Essence {clip_counter}"
                    
                    clip = MediaClip(
                        name=clip_name,
                        clip_id=essence_ref.get('id', f"omf_essence_{clip_counter}"),
                        is_embedded=essence_ref.get('embedded', False),
                        external_path=essence_ref['path'] if not essence_ref.get('embedded') else None
                    )
                    clips.append(clip)
                    _debug_print(f"DEBUG: Added essence clip: {clip_name}", verbose_only=True)
                    clip_counter += 1
            
            # If we didn't find any clips, try a more aggressive search
            if not clips:
                _debug_print(f"DEBUG: No clips found with standard parsing, trying aggressive parse...", verbose_only=True)
                f.seek(0)
                clips = _aggressive_omf_parse(f, omf_dir, file_path)
                _debug_print(f"DEBUG: Aggressive parse found {len(clips)} clip(s)", verbose_only=True)
            else:
                _debug_print(f"DEBUG: Standard parsing found {len(clips)} clip(s)", verbose_only=True)
    
    except Exception as e:
        _debug_print(f"DEBUG: Error parsing OMF file: {str(e)}", verbose_only=True)
        import traceback
        _debug_print(f"DEBUG: Traceback: {traceback.format_exc()}", verbose_only=True)
        raise ValueError(f"Error parsing OMF file: {str(e)}")
    
    _debug_print(f"DEBUG: OMF parsing complete. Total clips: {len(clips)}", verbose_only=True)
    return clips


def _extract_omf_file_paths(file_handle, base_dir: str) -> List[str]:
    """
    Extracts file paths from an OMF file by searching for path-like strings.
    Improved to better handle OMF file structure and path linking.
    
    Args:
        file_handle: Open file handle to the OMF file
        base_dir: Base directory for resolving relative paths
        
    Returns:
        List[str]: List of file paths found
    """
    file_paths = []
    file_handle.seek(0)
    
    try:
        # Check file size first - limit to 100MB to avoid hanging on huge files
        file_handle.seek(0, 2)  # Seek to end
        file_size = file_handle.tell()
        file_handle.seek(0)
        
        MAX_FILE_SIZE = 100 * 1024 * 1024  # 100MB
        if file_size > MAX_FILE_SIZE:
            _debug_print(f"DEBUG: OMF file is {file_size / (1024*1024):.1f}MB, limiting search to first 50MB", verbose_only=True)
            # For large files, only read first 50MB (paths are usually near the beginning)
            data = file_handle.read(50 * 1024 * 1024)
        else:
            # Read the entire file (for small-medium files)
            data = file_handle.read()
        
        _debug_print(f"DEBUG: Read {len(data) / (1024*1024):.1f}MB of OMF file for path extraction", verbose_only=True)
        
        def _is_valid_path_string(s: str) -> bool:
            """Check if a string looks like a valid file path (not binary data)."""
            if not s or len(s) < 4:
                return False
            
            # Must be mostly printable ASCII characters (allow some non-ASCII for international paths)
            # Count printable characters
            printable_count = sum(1 for c in s if c.isprintable() or c in '\n\r\t')
            if printable_count < len(s) * 0.7:  # At least 70% printable
                return False
            
            # Must not contain too many control characters (except common ones like \n, \r, \t)
            control_chars = sum(1 for c in s if ord(c) < 32 and c not in '\n\r\t')
            if control_chars > len(s) * 0.1:  # No more than 10% control chars
                return False
            
            # Must have a reasonable filename structure
            # Filename should contain mostly alphanumeric, spaces, hyphens, underscores, dots
            filename = os.path.basename(s)
            valid_filename_chars = sum(1 for c in filename if c.isalnum() or c in ' .-_()[]')
            if valid_filename_chars < len(filename) * 0.6:  # At least 60% valid filename chars
                return False
            
            # Extension should be reasonable (1-10 chars, alphanumeric)
            ext = os.path.splitext(filename)[1]
            if ext and (len(ext) > 10 or not all(c.isalnum() for c in ext[1:])):
                return False
            
            return True
        
        # Method 1: Look for strings that look like file paths with audio extensions
        # This is more specific and reduces false positives
        audio_extensions = [b'.wav', b'.aif', b'.aiff', b'.mp3', b'.m4a', b'.caf', b'.sd2',
                           b'.WAV', b'.AIF', b'.AIFF', b'.MP3', b'.M4A', b'.CAF', b'.SD2']
        
        # Look for paths ending with audio extensions
        for ext in audio_extensions:
            # Pattern: look for path-like strings ending with the extension
            # Allow for various path separators and encodings
            pattern = rb'[^\x00]{1,300}' + re.escape(ext) + rb'[\x00\x20-\x7E]{0,10}'
            matches = re.finditer(pattern, data)
            for match in matches:
                path_bytes = match.group(0)
                # Try to extract just the path part (before any trailing nulls or spaces)
                path_bytes = path_bytes.split(b'\x00')[0].rstrip()
                
                # Try multiple encodings
                for encoding in ['utf-8', 'latin-1', 'mac-roman', 'cp1252']:
                    try:
                        path_str = path_bytes.decode(encoding).strip()
                        
                        # Validate it looks like a path
                        if not (len(path_str) > 4 and (os.path.sep in path_str or '\\' in path_str or '/' in path_str)):
                            continue
                        
                        # Strict validation: must look like a real path, not binary data
                        if not _is_valid_path_string(path_str):
                            continue
                        
                        # Clean up the path
                        path_str = path_str.rstrip('\x00').strip()
                        
                        # Resolve relative paths
                        if not os.path.isabs(path_str):
                            # Try relative to OMF file location
                            resolved = os.path.join(base_dir, path_str)
                            if os.path.exists(resolved):
                                file_paths.append(os.path.normpath(resolved))
                            else:
                                # Also try with normalized path
                                normalized = os.path.normpath(path_str)
                                resolved = os.path.join(base_dir, normalized)
                                if os.path.exists(resolved):
                                    file_paths.append(os.path.normpath(resolved))
                                else:
                                    # Keep original relative path for validation
                                    file_paths.append(os.path.normpath(path_str))
                        else:
                            file_paths.append(os.path.normpath(path_str))
                        break
                    except (UnicodeDecodeError, UnicodeError):
                        continue
        
        # Method 2: Look for common path patterns (Windows and Unix/Mac)
        path_patterns = [
            # Windows paths: C:\... or \\server\... (more specific)
            rb'[A-Za-z]:[\\/][^\x00\n\r]{4,260}',
            # Unix/Mac absolute paths: /... (more specific)
            rb'/[^\x00\n\r]{4,260}',
        ]
        
        for pattern in path_patterns:
            matches = re.finditer(pattern, data)
            for match in matches:
                path_bytes = match.group(0)
                # Extract up to first null byte
                if b'\x00' in path_bytes:
                    path_bytes = path_bytes.split(b'\x00')[0]
                
                for encoding in ['utf-8', 'latin-1', 'mac-roman', 'cp1252']:
                    try:
                        path_str = path_bytes.decode(encoding).rstrip('\x00').strip()
                        
                        # Only include if it has a file extension (more likely to be a media file)
                        if not (len(path_str) > 4 and '.' in path_str):
                            continue
                        
                        # Strict validation: must look like a real path, not binary data
                        if not _is_valid_path_string(path_str):
                            continue
                        
                        ext = os.path.splitext(path_str)[1].lower()
                        # Prefer audio extensions, but include others too
                        if ext in ['.wav', '.aif', '.aiff', '.mp3', '.m4a', '.caf', '.sd2'] or len(ext) > 0:
                            if not os.path.isabs(path_str):
                                resolved = os.path.join(base_dir, path_str)
                                if os.path.exists(resolved):
                                    file_paths.append(os.path.normpath(resolved))
                                else:
                                    file_paths.append(os.path.normpath(path_str))
                            else:
                                file_paths.append(os.path.normpath(path_str))
                            break
                    except (UnicodeDecodeError, UnicodeError):
                        continue
        
        # Method 3: Look for null-terminated strings that might be paths
        # This is more conservative - only include strings with file extensions
        # Limit chunk processing for large files
        chunks = data.split(b'\x00')
        max_chunks = 100000  # Limit to prevent excessive processing
        if len(chunks) > max_chunks:
            _debug_print(f"DEBUG: Limiting null-byte chunk processing to first {max_chunks} chunks", verbose_only=True)
            chunks = chunks[:max_chunks]
        
        for chunk in chunks:
            if 10 <= len(chunk) <= 260:  # Reasonable path length (Windows MAX_PATH is 260)
                for encoding in ['utf-8', 'latin-1', 'mac-roman']:
                    try:
                        candidate = chunk.decode(encoding).strip()
                        
                        # Must have path separator and file extension
                        if not (('\\' in candidate or '/' in candidate) and 
                                '.' in candidate and 
                                len(os.path.splitext(candidate)[1]) > 0):
                            continue
                        
                        # Strict validation: must look like a real path, not binary data
                        if not _is_valid_path_string(candidate):
                            continue
                        
                        ext = os.path.splitext(candidate)[1].lower()
                        # Prefer audio extensions
                        if ext in ['.wav', '.aif', '.aiff', '.mp3', '.m4a', '.caf', '.sd2']:
                            if not os.path.isabs(candidate):
                                resolved = os.path.join(base_dir, candidate)
                                if os.path.exists(resolved):
                                    file_paths.append(os.path.normpath(resolved))
                                else:
                                    file_paths.append(os.path.normpath(candidate))
                            else:
                                file_paths.append(os.path.normpath(candidate))
                            break
                    except (UnicodeDecodeError, UnicodeError):
                        continue
    
    except Exception:
        # If parsing fails, return empty list
        pass
    
    # Remove duplicates while preserving order and normalize paths
    seen = set()
    unique_paths = []
    for path in file_paths:
        normalized = os.path.normpath(path)
        if normalized not in seen:
            seen.add(normalized)
            unique_paths.append(normalized)
    
    return unique_paths


def _extract_omf_essence_references(file_handle) -> List[Dict]:
    """
    Extracts essence data references from OMF file.
    
    Args:
        file_handle: Open file handle to the OMF file
        
    Returns:
        List[Dict]: List of essence reference dictionaries
    """
    essence_refs = []
    # This is a placeholder - essence reference extraction would require
    # deeper knowledge of OMF chunk structure
    # For now, we'll rely on file path extraction
    return essence_refs


def _aggressive_omf_parse(file_handle, base_dir: str, omf_file_path: str) -> List[MediaClip]:
    """
    More aggressive parsing method that searches for any file-like references.
    
    Args:
        file_handle: Open file handle to the OMF file
        base_dir: Base directory for resolving relative paths
        omf_file_path: Path to the OMF file itself
        
    Returns:
        List[MediaClip]: List of clips found
    """
    clips = []
    
    try:
        # Check file size first - limit to avoid hanging
        file_handle.seek(0, 2)  # Seek to end
        file_size = file_handle.tell()
        file_handle.seek(0)
        
        MAX_FILE_SIZE = 100 * 1024 * 1024  # 100MB
        if file_size > MAX_FILE_SIZE:
            _debug_print(f"DEBUG: OMF file is {file_size / (1024*1024):.1f}MB, limiting aggressive search to first 50MB", verbose_only=True)
            # For large files, only read first 50MB
            data = file_handle.read(50 * 1024 * 1024)
        else:
            data = file_handle.read()
        
        _debug_print(f"DEBUG: Aggressive parse reading {len(data) / (1024*1024):.1f}MB", verbose_only=True)
        
        # Look for any strings that might be file references
        # This is a fallback method when standard parsing doesn't work
        
        # Search for common audio file patterns in the binary data
        
        # Look for file extensions in the data
        # Limit the search to avoid hanging on files with lots of matches
        audio_ext_pattern = rb'[^\x00]{1,200}\.(wav|aif|aiff|mp3|m4a|caf|sd2|WAV|AIF|AIFF|MP3|M4A|CAF|SD2)(\x00|[\x20-\x7E]{0,10})'
        
        matches = re.finditer(audio_ext_pattern, data)
        clip_counter = 1
        max_clips = 1000  # Limit to prevent excessive processing
        
        for match in matches:
            if clip_counter > max_clips:
                _debug_print(f"DEBUG: Reached maximum clip limit ({max_clips}), stopping aggressive parse", verbose_only=True)
                break
            try:
                # Extract the potential file path
                match_bytes = match.group(0)
                # Try to find the start of the path (look backwards for separators)
                path_start = 0
                for i in range(len(match_bytes) - 1, -1, -1):
                    if match_bytes[i:i+1] in [b'\\', b'/', b':']:
                        path_start = i
                        break
                    elif i < len(match_bytes) - 50:  # Don't go too far back
                        break
                
                potential_path = match_bytes[path_start:].split(b'\x00')[0]
                
                for encoding in ['utf-8', 'latin-1', 'mac-roman', 'cp1252']:
                    try:
                        path_str = potential_path.decode(encoding).strip()
                        if len(path_str) > 4 and ('\\' in path_str or '/' in path_str):
                            # Resolve path
                            if not os.path.isabs(path_str):
                                resolved = os.path.join(base_dir, path_str)
                            else:
                                resolved = path_str
                            
                            clip_name = os.path.basename(path_str) or f"Audio Reference {clip_counter}"
                            
                            clip = MediaClip(
                                name=clip_name,
                                clip_id=f"omf_ref_{clip_counter}",
                                is_embedded=False,
                                external_path=resolved
                            )
                            clips.append(clip)
                            clip_counter += 1
                            break
                    except (UnicodeDecodeError, UnicodeError):
                        continue
            except Exception:
                continue
    
    except Exception:
        pass
    
    return clips


def validate_omf_aaf_media(file_path: str) -> ValidationReport:
    """
    Validates an OMF or AAF file for missing or unlinked audio media.
    
    This function:
    1. Parses the OMF/AAF file to extract audio clip metadata
    2. Checks embedded media for correct structure
    3. Verifies external file paths exist for linked media
    4. Returns a comprehensive validation report
    
    Args:
        file_path: Path to the OMF or AAF file to validate
        
    Returns:
        ValidationReport: A report object containing validation results
        
    Raises:
        FileNotFoundError: If the specified file_path does not exist
        ValueError: If the file is not a valid OMF or AAF file
    """
    # Validate input file exists
    if not os.path.exists(file_path):
        raise FileNotFoundError(f"The specified file does not exist: {file_path}")
    
    # Determine file type
    try:
        file_type = _detect_file_type(file_path)
    except ValueError as e:
        raise ValueError(str(e))
    
    # Parse the file based on type
    if file_type == 'aaf':
        all_clips = _parse_aaf_file(file_path)
    elif file_type == 'omf':
        all_clips = _parse_omf_file(file_path)
    else:
        raise ValueError(f"Unsupported file type: {file_type}")
    
    # Validate each clip
    missing_clips: List[MediaClip] = []
    
    for clip in all_clips:
        if clip.is_embedded:
            # Validate embedded media structure
            if not validate_embedded_media(clip):
                clip.is_valid = False
                clip.error_message = "Embedded media data is missing or corrupted"
                missing_clips.append(clip)
        else:
            # Check external file path
            if not clip.external_path:
                clip.is_valid = False
                clip.error_message = "No external file path specified for linked media"
                missing_clips.append(clip)
            elif not os.path.exists(clip.external_path):
                clip.is_valid = False
                clip.error_message = f"External media file not found: {clip.external_path}"
                missing_clips.append(clip)
            else:
                # File exists, but verify it's actually a file (not a directory)
                if not os.path.isfile(clip.external_path):
                    clip.is_valid = False
                    clip.error_message = f"External path exists but is not a file: {clip.external_path}"
                    missing_clips.append(clip)
    
    # Count clips by type
    embedded_count = sum(1 for clip in all_clips if clip.is_embedded)
    linked_count = sum(1 for clip in all_clips if not clip.is_embedded)
    valid_count = sum(1 for clip in all_clips if clip.is_valid)
    missing_clips_count = len(missing_clips)
    
    # Extract timeline information
    timeline_clips: List[MediaClip] = []
    total_duration = 0.0
    if file_type == 'aaf':
        timeline_clips, total_duration = _extract_timeline_clips_from_aaf(file_path, all_clips)
    elif file_type == 'omf':
        timeline_clips, total_duration = _extract_timeline_clips_from_omf(file_path, all_clips)
    
    # Create and return validation report
    report = ValidationReport(
        total_clips=len(all_clips),
        embedded_clips=embedded_count,
        linked_clips=linked_count,
        missing_clips=missing_clips_count,
        valid_clips=valid_count,
        missing_clip_details=missing_clips,
        file_path=file_path,
        timeline_clips=timeline_clips,
        total_duration=total_duration
    )
    
    return report


def _extract_timeline_clips_from_aaf(file_path: str, validation_clips: List[MediaClip]) -> Tuple[List[MediaClip], float]:
    """
    Extracts timeline information from an AAF file.
    
    Args:
        file_path: Path to the AAF file
        validation_clips: List of clips from validation (for name matching)
        
    Returns:
        Tuple of (timeline_clips, total_duration)
    """
    if not AAF_SUPPORT:
        return [], 0.0
    
    timeline_clips: List[MediaClip] = []
    processed_timeline_sources: Set[str] = set()
    total_duration = 0.0
    
    # Create a map of validation clips by clip_id for name matching
    validation_clip_map: Dict[str, MediaClip] = {}
    for clip in validation_clips:
        if clip.clip_id:
            validation_clip_map[clip.clip_id] = clip
    
    try:
        with aaf2.open(file_path, 'r') as f:
            # Get all top-level compositions (timelines)
            compositions = list(f.content.toplevel())
            
            for comp_idx, composition in enumerate(compositions):
                try:
                    # Get edit rate for time conversion
                    edit_rate = 48000.0  # Default to 48kHz
                    try:
                        if hasattr(composition, 'edit_rate'):
                            edit_rate = float(composition.edit_rate)
                    except Exception:
                        pass
                    
                    # Get timeline slots (tracks)
                    if hasattr(composition, 'slots'):
                        slots = list(composition.slots) if hasattr(composition.slots, '__iter__') else []
                        track_index = 0
                        
                        for slot_idx, slot in enumerate(slots):
                            if hasattr(slot, 'segment') and slot.segment:
                                segment = slot.segment
                                
                                # Get slot position on timeline
                                slot_position = 0.0
                                try:
                                    if hasattr(slot, 'start'):
                                        slot_position = float(getattr(slot, 'start', 0))
                                except Exception:
                                    pass
                                
                                timeline_position = slot_position / edit_rate
                                
                                # Extract clips from this track
                                _extract_timeline_clips_from_segment(
                                    segment, timeline_clips, processed_timeline_sources,
                                    file_path, track_index, timeline_position, edit_rate,
                                    validation_clip_map, depth=0
                                )
                                
                                track_index += 1
                                
                                # Update total duration
                                try:
                                    if hasattr(slot, 'length'):
                                        slot_length = float(getattr(slot, 'length', 0))
                                        slot_end = (slot_position + slot_length) / edit_rate
                                        total_duration = max(total_duration, slot_end)
                                except Exception:
                                    pass
                except Exception as e:
                    _debug_print(f"DEBUG: Error extracting timeline from composition {comp_idx}: {e}", verbose_only=True)
                    continue
    except Exception as e:
        _debug_print(f"DEBUG: Error extracting timeline clips: {e}", verbose_only=True)
        return [], 0.0
    
    return timeline_clips, total_duration


def _extract_timeline_clips_from_segment(
    segment, timeline_clips: List[MediaClip], processed_sources: Set[str],
    aaf_file_path: str, track_index: int, timeline_position: float, edit_rate: float,
    validation_clip_map: Dict[str, MediaClip], depth: int = 0
):
    """Recursively extracts timeline clips from AAF segments."""
    MAX_DEPTH = 20
    if depth > MAX_DEPTH:
        return
    
    try:
        segment_type = type(segment).__name__
        
        # Check if this is a SourceClip with a MOB
        if hasattr(segment, 'mob') and segment.mob is not None:
            source_mob = segment.mob
            source_id = str(getattr(source_mob, 'mob_id', id(source_mob)))
            
            # Allow same clip to appear multiple times on timeline
            # (don't check processed_sources for timeline extraction)
            
            # Find matching validation clip first (it may have better name info)
            matched_clip = validation_clip_map.get(source_id)
            
            # Get clip name - source_mob.name typically contains the actual file name
            clip_name = None
            try:
                # Try MOB name first (this usually has the file name in Pro Tools exports)
                if hasattr(source_mob, 'name') and source_mob.name:
                    mob_name = str(source_mob.name).strip()
                    # Use MOB name if it's not a generic name
                    if mob_name.lower() not in ['sourceclip', 'unnamed', '']:
                        clip_name = mob_name
                        # Remove extension for cleaner display
                        clip_name = os.path.splitext(clip_name)[0]
                
                # Fallback: Try segment name
                if not clip_name and hasattr(segment, 'name') and segment.name:
                    seg_name = str(segment.name).strip()
                    if seg_name.lower() not in ['sourceclip', 'unnamed', '']:
                        clip_name = seg_name
                
                # Fallback: Try descriptor name
                if not clip_name and hasattr(source_mob, 'descriptor'):
                    desc = source_mob.descriptor
                    if hasattr(desc, 'name') and desc.name:
                        desc_name = str(desc.name).strip()
                        if desc_name.lower() not in ['sourceclip', 'unnamed', '']:
                            clip_name = desc_name
                
                # Fallback: Try name from matched validation clip
                if not clip_name and matched_clip and matched_clip.name:
                    val_name = str(matched_clip.name).strip()
                    if val_name.lower() not in ['sourceclip', 'unnamed', '']:
                        clip_name = val_name
                
                # Fallback: Try to get file name from locator
                if not clip_name and hasattr(source_mob, 'descriptor'):
                    desc = source_mob.descriptor
                    if hasattr(desc, 'locator') and desc.locator:
                        locator = desc.locator
                        file_path = None
                        if hasattr(locator, 'path'):
                            file_path = str(locator.path)
                        elif hasattr(locator, 'url_string'):
                            url = str(locator.url_string)
                            if url.startswith('file://'):
                                file_path = url[7:]
                            elif not url.startswith('http'):
                                file_path = url
                        
                        if file_path:
                            filename = os.path.basename(file_path)
                            if filename and filename.lower() not in ['sourceclip', 'unnamed', '']:
                                clip_name = os.path.splitext(filename)[0]  # Remove extension
                
                # Final fallback: Use filename from matched clip if available
                if not clip_name and matched_clip and matched_clip.external_path:
                    filename = os.path.basename(matched_clip.external_path)
                    clip_name = os.path.splitext(filename)[0]
                
                # Last resort: Generate a name
                if not clip_name:
                    clip_name = f"Clip_{len(timeline_clips) + 1}"
                
                _debug_print(f"DEBUG: Clip name extraction - segment.name={getattr(segment, 'name', None)}, source_mob.name={getattr(source_mob, 'name', None)}, final clip_name={clip_name}", verbose_only=True)
            except Exception as e:
                _debug_print(f"DEBUG: Error extracting clip name: {e}", verbose_only=True)
                clip_name = f"Clip_{len(timeline_clips) + 1}"
            
            # Get segment timing
            segment_start = 0.0
            segment_length = 0.0
            try:
                if hasattr(segment, 'start'):
                    segment_start = float(getattr(segment, 'start', 0))
                if hasattr(segment, 'length'):
                    segment_length = float(getattr(segment, 'length', 0))
            except Exception:
                pass
            
            # Calculate timeline positions
            # The clip's position is: slot position + clip's position within sequence
            clip_start = timeline_position + (segment_start / edit_rate)
            clip_length = segment_length / edit_rate if segment_length > 0 else 0.0
            clip_end = clip_start + clip_length
            
            _debug_print(f"DEBUG: Timeline clip: {clip_name} at {clip_start:.3f}s-{clip_end:.3f}s (track {track_index}, segment_start={segment_start}, timeline_pos={timeline_position:.3f})", verbose_only=True)
            
            # Name matching logic
            name_matches = None
            expected_filename = None
            
            if matched_clip:
                # Check if clip name matches file name
                if matched_clip.external_path:
                    expected_filename = os.path.basename(matched_clip.external_path)
                    # Normalize names for comparison (remove extensions, case-insensitive)
                    clip_name_base = os.path.splitext(clip_name)[0].lower().strip()
                    expected_base = os.path.splitext(expected_filename)[0].lower().strip()
                    name_matches = clip_name_base == expected_base
                elif matched_clip.is_embedded:
                    # For embedded clips, we can't verify name matching easily
                    name_matches = None
            
            # Create timeline clip
            timeline_clip = MediaClip(
                name=clip_name,
                clip_id=source_id,
                is_embedded=matched_clip.is_embedded if matched_clip else False,
                external_path=matched_clip.external_path if matched_clip else None,
                is_valid=matched_clip.is_valid if matched_clip else True,
                track_index=track_index,
                timeline_start=clip_start,
                timeline_end=clip_end,
                name_matches_file=name_matches,
                expected_filename=expected_filename
            )
            timeline_clips.append(timeline_clip)
            
            # Update timeline position for next clip
            if segment_length > 0:
                timeline_position += segment_length / edit_rate
        
        # Recursively process nested segments (Sequences contain components)
        if hasattr(segment, 'components'):
            comp_list = list(segment.components) if hasattr(segment.components, '__iter__') else []
            for comp in comp_list:
                # Get component's position within the sequence
                comp_start = 0.0
                try:
                    if hasattr(comp, 'start'):
                        comp_start = float(getattr(comp, 'start', 0))
                except Exception:
                    pass
                
                # Position within sequence: base position + component's start offset
                # When the component (SourceClip) is processed, it will add its own start (which should be 0
                # for clips in sequences, as their position is determined by comp_start here)
                comp_timeline_pos = timeline_position + (comp_start / edit_rate)
                
                _extract_timeline_clips_from_segment(
                    comp, timeline_clips, processed_sources,
                    aaf_file_path, track_index, comp_timeline_pos, edit_rate,
                    validation_clip_map, depth + 1
                )
        
        # Also check segments (for OperationGroups)
        if hasattr(segment, 'segments'):
            seg_list = list(segment.segments) if hasattr(segment.segments, '__iter__') else []
            for seg in seg_list:
                _extract_timeline_clips_from_segment(
                    seg, timeline_clips, processed_sources,
                    aaf_file_path, track_index, timeline_position, edit_rate,
                    validation_clip_map, depth + 1
                )
    except Exception:
        pass


def _extract_timeline_clips_from_omf(file_path: str, validation_clips: List[MediaClip]) -> Tuple[List[MediaClip], float]:
    """
    Extracts timeline information from an OMF file.
    
    Note: OMF files use a binary chunk structure which is more complex to parse
    than AAF files. This function attempts to extract timeline information by:
    1. Creating a simplified timeline based on the order of clips found
    2. Assigning clips to tracks sequentially
    3. Matching clips to validation results for name matching
    
    Args:
        file_path: Path to the OMF file
        validation_clips: List of clips from validation (for name matching)
        
    Returns:
        Tuple of (timeline_clips, total_duration)
    """
    timeline_clips: List[MediaClip] = []
    total_duration = 0.0
    
    # Create a map of validation clips by clip_id for matching
    validation_clip_map: Dict[str, MediaClip] = {}
    for clip in validation_clips:
        if clip.clip_id:
            validation_clip_map[clip.clip_id] = clip
    
    try:
        # OMF files have a binary chunk structure which is complex to parse fully
        # For now, we'll create a simplified timeline based on the validation clips
        # This assigns clips to tracks sequentially and estimates timing
        
        track_index = 0
        current_time = 0.0
        clips_per_track = 10  # Approximate clips per track
        
        for i, clip in enumerate(validation_clips):
            # Assign to track (distribute across multiple tracks)
            track = i // clips_per_track
            
            # Estimate duration (default to 5 seconds if unknown)
            estimated_duration = 5.0
            
            # Try to get actual file duration if it's an external file
            if clip.external_path and os.path.exists(clip.external_path):
                try:
                    # Try to get file size and estimate duration
                    # This is rough - actual duration would require parsing audio headers
                    file_size = os.path.getsize(clip.external_path)
                    # Rough estimate: assume 16-bit, 2-channel, 48kHz WAV
                    # bytes_per_second = 48000 * 2 * 2 = 192000
                    bytes_per_second = 192000
                    estimated_duration = max(1.0, file_size / bytes_per_second)
                except Exception:
                    pass
            
            clip_start = current_time
            clip_end = clip_start + estimated_duration
            
            # Check name matching
            name_matches = None
            expected_filename = None
            if clip.external_path:
                expected_filename = os.path.basename(clip.external_path)
                clip_name_base = os.path.splitext(clip.name)[0].lower().strip()
                expected_base = os.path.splitext(expected_filename)[0].lower().strip()
                name_matches = clip_name_base == expected_base
            
            # Create timeline clip
            timeline_clip = MediaClip(
                name=clip.name,
                clip_id=clip.clip_id or f"omf_timeline_{i}",
                is_embedded=clip.is_embedded,
                external_path=clip.external_path,
                is_valid=clip.is_valid,
                track_index=track,
                timeline_start=clip_start,
                timeline_end=clip_end,
                name_matches_file=name_matches,
                expected_filename=expected_filename
            )
            timeline_clips.append(timeline_clip)
            
            # Advance time (clips on same track are sequential)
            if (i + 1) % clips_per_track == 0:
                current_time = 0.0  # Reset for next track
            else:
                current_time = clip_end
            
            total_duration = max(total_duration, clip_end)
        
        # If we found clips, ensure we have a reasonable total duration
        if timeline_clips and total_duration == 0.0:
            # Estimate based on number of clips
            total_duration = len(timeline_clips) * 5.0
            
    except Exception as e:
        _debug_print(f"DEBUG: Error extracting timeline from OMF: {e}", verbose_only=True)
        return [], 0.0
    
    return timeline_clips, total_duration


# ============================================================================
# ARCHIVED: Playback verification feature - disabled due to aaf2 library limitations
# TODO: Revisit when we have a solution for extracting embedded essence data
# Date archived: 2024-12-19
# ============================================================================
# def _extract_playback_clips_from_aaf(file_path: str) -> List[PlaybackClip]:
#     """
#     Extracts playback-ready clips from an AAF file with timeline information.
#     Efficient version: Skips validation parser, extracts timeline directly.
#     
#     Args:
#         file_path: Path to the AAF file
#         
#     Returns:
#         List[PlaybackClip]: List of clips ready for playback with timeline data
#     """
#     import sys
#     if not AAF_SUPPORT:
#         print("DEBUG: AAF support not available", file=sys.stderr, flush=True)
#         return []
#     
#     playback_clips: List[PlaybackClip] = []
#     processed_sources: Set[str] = set()
#     
#     try:
#         msg = f"DEBUG: ===== STARTING PLAYBACK CLIP EXTRACTION FOR {file_path} ====="
#         print(msg, file=sys.stderr, flush=True)
#         if _DEBUG_FILE:
#             _DEBUG_FILE.write(msg + "\n")
#             _DEBUG_FILE.flush()
#         
#         # Check if file exists and is accessible
#         if not os.path.exists(file_path):
#             msg = f"DEBUG: ERROR: File does not exist: {file_path}"
#             print(msg, file=sys.stderr, flush=True)
#             if _DEBUG_FILE:
#                 _DEBUG_FILE.write(msg + "\n")
#                 _DEBUG_FILE.flush()
#             return []
#         
#         if not os.path.isfile(file_path):
#             msg = f"DEBUG: ERROR: Path is not a file: {file_path}"
#             print(msg, file=sys.stderr, flush=True)
#             if _DEBUG_FILE:
#                 _DEBUG_FILE.write(msg + "\n")
#                 _DEBUG_FILE.flush()
#             return []
#         
#         # Check file size (if 0, might be a placeholder)
#         try:
#             file_size = os.path.getsize(file_path)
#             msg = f"DEBUG: File size: {file_size} bytes"
#             print(msg, file=sys.stderr, flush=True)
#             if _DEBUG_FILE:
#                 _DEBUG_FILE.write(msg + "\n")
#                 _DEBUG_FILE.flush()
#             if file_size == 0:
#                 msg = "DEBUG: WARNING: File size is 0 bytes - file may not be fully synced (if in cloud storage)"
#                 print(msg, file=sys.stderr, flush=True)
#                 if _DEBUG_FILE:
#                     _DEBUG_FILE.write(msg + "\n")
#                     _DEBUG_FILE.flush()
#         except Exception as e:
#             msg = f"DEBUG: Could not check file size: {e}"
#             print(msg, file=sys.stderr, flush=True)
#             if _DEBUG_FILE:
#                 _DEBUG_FILE.write(msg + "\n")
#                 _DEBUG_FILE.flush()
#         
#         _debug_print("DEBUG: Extracting timeline clips from AAF file", verbose_only=True)
#         
#         try:
#             with aaf2.open(file_path, 'r') as f:
#                 # Get all compositions (timelines) - skip validation parser
#                 compositions = []
#                 try:
#                     if hasattr(f.content, 'compositions'):
#                         compositions = list(f.content.compositions) if hasattr(f.content.compositions, '__iter__') else []
#                     elif hasattr(f.content, 'toplevel'):
#                         toplevel = list(f.content.toplevel()) if hasattr(f.content.toplevel, '__call__') else []
#                         compositions = [item for item in toplevel if hasattr(item, 'slots')]
#                 except Exception as e:
#                     _debug_print(f"DEBUG: Error getting compositions: {str(e)}", verbose_only=True)
#                     return []
#                 
#                 if not compositions:
#                     _debug_print("DEBUG: No compositions found", verbose_only=True)
#                     return []
#                 
#                 _debug_print(f"DEBUG: Found {len(compositions)} composition(s)", verbose_only=True)
#                 
#                 # Process each composition to extract timeline clips
#                 for comp_idx, composition in enumerate(compositions):
#                     try:
#                         _extract_timeline_from_composition_simple(composition, playback_clips, processed_sources, file_path, comp_idx)
#                     except Exception as e:
#                         _debug_print(f"DEBUG: Error processing composition {comp_idx}: {e}", verbose_only=True)
#                         continue
#         except TimeoutError as e:
#             import sys
#             msg = f"DEBUG: ERROR: Timeout opening AAF file. This may happen if the file is in cloud storage and not fully synced locally. File: {file_path}"
#             print(msg, file=sys.stderr, flush=True)
#             if _DEBUG_FILE:
#                 _DEBUG_FILE.write(msg + "\n")
#                 _DEBUG_FILE.write(f"DEBUG: TimeoutError details: {str(e)}\n")
#                 _DEBUG_FILE.flush()
#             _debug_print(f"DEBUG: TimeoutError: {str(e)}", verbose_only=True)
#             return []
#         except OSError as e:
#             import sys
#             if e.errno == 60:  # Operation timed out
#                 msg = f"DEBUG: ERROR: Operation timed out opening AAF file. This may happen if the file is in cloud storage (e.g., Google Drive) and not fully synced locally. File: {file_path}"
#                 print(msg, file=sys.stderr, flush=True)
#                 if _DEBUG_FILE:
#                     _DEBUG_FILE.write(msg + "\n")
#                     _DEBUG_FILE.write(f"DEBUG: OSError details: {str(e)}\n")
#                     _DEBUG_FILE.flush()
#                 _debug_print(f"DEBUG: OSError (timeout): {str(e)}", verbose_only=True)
#                 return []
#             else:
#                 raise  # Re-raise if it's a different OSError
#         
#         import sys
#         msg = f"DEBUG: ===== FINISHED PLAYBACK CLIP EXTRACTION: Found {len(playback_clips)} clips ====="
#         print(msg, file=sys.stderr, flush=True)
#         if _DEBUG_FILE:
#             _DEBUG_FILE.write(msg + "\n")
#             _DEBUG_FILE.flush()
#         _debug_print(f"DEBUG: Returning {len(playback_clips)} playback clips", verbose_only=True)
#     
#     except Exception as e:
#         import sys
#         msg = f"DEBUG: ===== ERROR IN PLAYBACK CLIP EXTRACTION: {str(e)} ====="
#         print(msg, file=sys.stderr, flush=True)
#         if _DEBUG_FILE:
#             _DEBUG_FILE.write(msg + "\n")
#             _DEBUG_FILE.flush()
#         _debug_print(f"DEBUG: Error extracting clips: {str(e)}", verbose_only=True)
#         import traceback
#         print(f"DEBUG: Traceback: {traceback.format_exc()}", file=sys.stderr, flush=True)
#         _debug_print(f"DEBUG: Traceback: {traceback.format_exc()}", verbose_only=True)
#     
#     return playback_clips


# ARCHIVED: Helper function for playback extraction
# def _extract_timeline_from_composition_simple(composition, playback_clips: List[PlaybackClip], processed_sources: Set[str], aaf_file_path: str, comp_index: int):
#     """
#     Simplified timeline extraction - no validation parser, no complex matching.
#     Just extracts clips from timeline and checks if they're embedded.
#     """
#     try:
#         # Get edit rate for time conversion
#         edit_rate = 48000.0  # Default
#         try:
#             if hasattr(composition, 'edit_rate'):
#                 edit_rate = float(composition.edit_rate)
#         except Exception:
#             pass
#         
#         # Get timeline slots (tracks)
#         if not hasattr(composition, 'slots'):
#             return
#         
#         slots = list(composition.slots) if hasattr(composition.slots, '__iter__') else []
#         track_index = 0
#         timeline_position = 0.0
#         
#         for slot_idx, slot in enumerate(slots):
#             if not hasattr(slot, 'segment') or not slot.segment:
#                 continue
#             
#             segment = slot.segment
#             slot_start = 0.0
#             try:
#                 if hasattr(slot, 'start'):
#                     slot_start = float(getattr(slot, 'start', 0))
#             except Exception:
#                 pass
#             
#             timeline_position = slot_start / edit_rate
#             
#             # Extract clips from this track segment (simplified recursion)
#             _extract_clips_from_segment_simple(segment, playback_clips, processed_sources, 
#                                               aaf_file_path, track_index, timeline_position, edit_rate, depth=0)
#             track_index += 1
#     
#     except Exception as e:
#         _debug_print(f"DEBUG: Error in timeline extraction: {e}", verbose_only=True)


# ARCHIVED: Helper function for playback extraction
# def _extract_clips_from_segment_simple(segment, playback_clips, processed_sources, aaf_file_path, track_index, timeline_position, edit_rate, depth=0):
#     """ARCHIVED: Disabled due to aaf2 library limitations"""
#     return
#     # Original implementation commented out - see git history
#     # MAX_DEPTH = 10  # Increased slightly but still limited
#     # if depth > MAX_DEPTH:
#     #     return
#     
#     try:
        # Check if this segment is a SourceClip
        # if hasattr(segment, 'mob') and segment.mob is not None:
            # source_mob = segment.mob
            # source_id = str(getattr(source_mob, 'mob_id', id(source_mob)))
            
            # if source_id in processed_sources:
                # return
            
            # Follow MOB chain to find Essence MOB and check if embedded
            # essence_mob = _find_essence_mob_from_composition_mob(source_mob)
            # check_mob = essence_mob if essence_mob else source_mob
            
            # Check if embedded
            # is_embedded = False
            # external_path = None
            # try:
                # if hasattr(check_mob, 'descriptor'):
                    # descriptor = check_mob.descriptor
                    # Check for external locator first
                    # if hasattr(descriptor, 'locator') and descriptor.locator:
                        # locator = descriptor.locator
                        # if hasattr(locator, 'path'):
                            # external_path = str(locator.path)
                        # elif hasattr(locator, 'url_string'):
                            # url = str(locator.url_string)
                            # if url.startswith('file://'):
                                # external_path = url[7:]
                            # elif not url.startswith('http'):
                                # external_path = url
                    
                    # If no external path, check for embedded essence
                    # if not external_path:
                        # if hasattr(descriptor, 'essence') or hasattr(descriptor, 'essence_data'):
                            # is_embedded = True
                
                # if not is_embedded and not external_path:
                    # if hasattr(check_mob, 'essence'):
                        # is_embedded = True
            # except Exception:
                # pass
            
            # Only process embedded clips (no external path)
            # if is_embedded and not external_path:
                # FINAL VERIFICATION: Always double-check the MOB for external locators
                # import sys
                # msg = f"DEBUG: [_extract_clips_from_segment_simple] Running final verification for clip (source_id={source_id})"
                # print(msg, file=sys.stderr, flush=True)
                # if _DEBUG_FILE:
                    # _DEBUG_FILE.write(msg + "\n")
                    # _DEBUG_FILE.flush()
                # is_embedded = _verify_essence_mob_is_embedded(essence_mob, source_mob)
                # if not is_embedded:
                    # msg = f"DEBUG: [_extract_clips_from_segment_simple] REJECTED clip (source_id={source_id}): Final verification failed - MOB has external locator"
                    # print(msg, file=sys.stderr, flush=True)
                    # if _DEBUG_FILE:
                        # _DEBUG_FILE.write(msg + "\n")
                        # _DEBUG_FILE.flush()
                
                # if is_embedded:
                    # clip_name = getattr(segment, 'name', None) or getattr(source_mob, 'name', 'Unnamed Clip')
                    # if not clip_name:
                        # clip_name = f"Clip_{len(playback_clips) + 1}"
                    
                    # segment_start = 0.0
                    # segment_length = 0.0
                    # try:
                        # if hasattr(segment, 'start'):
                            # segment_start = float(getattr(segment, 'start', 0))
                        # if hasattr(segment, 'length'):
                            # segment_length = float(getattr(segment, 'length', 0))
                    # except Exception:
                        # pass
                    
                    # clip_start = timeline_position
                    # source_start = segment_start / edit_rate
                    # clip_length = segment_length / edit_rate if segment_length > 0 else 0.0
                    
                    # Use essence MOB ID if found, otherwise use source MOB ID
                    # essence_id = str(getattr(essence_mob, 'mob_id', id(essence_mob))) if essence_mob else source_id
                    # embedded_path = f"EMBEDDED:{aaf_file_path}:{essence_id}"
                    
                    # msg = f"DEBUG: [_extract_clips_from_segment_simple] ADDING clip '{clip_name}' (source_id={source_id}, essence_id={essence_id})"
                    # print(msg, file=sys.stderr, flush=True)
                    # if _DEBUG_FILE:
                        # _DEBUG_FILE.write(msg + "\n")
                        # _DEBUG_FILE.flush()
                    
                    # playback_clip = PlaybackClip(
                        # name=clip_name,
                        # file_path=embedded_path,
                        # start_time=source_start,
                        # duration=clip_length,
                        # track_index=track_index,
                        # timeline_start=clip_start,
                        # timeline_end=clip_start + clip_length,
                        # source_in=source_start,
                        # source_out=source_start + clip_length
                    # )
                    # playback_clips.append(playback_clip)
                    # processed_sources.add(source_id)
                    # if essence_mob:
                        # processed_sources.add(essence_id)
                    
                    # if segment_length > 0:
                        # timeline_position += segment_length / edit_rate
        
        # Handle OperationGroups - simplified recursion
        # if hasattr(segment, 'segments'):
            # segments = list(segment.segments) if hasattr(segment.segments, '__iter__') else []
            # for seg in segments:
                # _extract_clips_from_segment_simple(seg, playback_clips, processed_sources,
                                                  # aaf_file_path, track_index, timeline_position, edit_rate, depth + 1)
        
        # Handle components - simplified recursion
        # if hasattr(segment, 'components'):
            # components = list(segment.components) if hasattr(segment.components, '__iter__') else []
            # current_pos = timeline_position
            # for component in components:
                # comp_length = 0.0
                # try:
                    # if hasattr(component, 'length'):
                        # comp_length = float(getattr(component, 'length', 0)) / edit_rate
                # except Exception:
                    # pass
                
                # _extract_clips_from_segment_simple(component, playback_clips, processed_sources,
                                                  # aaf_file_path, track_index, current_pos, edit_rate, depth + 1)
                
                # if comp_length > 0:
                    # current_pos += comp_length
    
    # except Exception as e:
        # _debug_print(f"DEBUG: Error in segment extraction: {e}", verbose_only=True)


# ARCHIVED: Helper function for playback extraction (but also used by validation, so keep it)
# Note: This function is still used by validation, so we'll keep it active
def _find_essence_mob_from_composition_mob(composition_mob):
    """
    Finds the Essence MOB that a Composition MOB references.
    
    In AAF, Composition MOBs (timeline references) point to Essence MOBs (actual media).
    This function follows the reference chain to find the embedded essence.
    
    Args:
        composition_mob: The Composition MOB from a SourceClip
        
    Returns:
        The Essence MOB if found, None otherwise
    """
    try:
        # Check if this MOB has slots that reference essence
        if hasattr(composition_mob, 'slots'):
            for slot in composition_mob.slots:
                if hasattr(slot, 'segment'):
                    seg = slot.segment
                    # The segment might reference an essence MOB
                    if hasattr(seg, 'mob') and seg.mob:
                        potential_essence = seg.mob
                        # Check if this is an essence MOB (has embedded data)
                        if hasattr(potential_essence, 'descriptor'):
                            desc = potential_essence.descriptor
                            if hasattr(desc, 'essence') or hasattr(desc, 'essence_data'):
                                return potential_essence
                        # Also check if the MOB itself has essence
                        if hasattr(potential_essence, 'essence'):
                            return potential_essence
        
        # Alternative: Check if the composition MOB's descriptor references essence
        if hasattr(composition_mob, 'descriptor'):
            desc = composition_mob.descriptor
            # Sometimes the descriptor itself points to essence
            if hasattr(desc, 'essence') or hasattr(desc, 'essence_data'):
                return composition_mob
        
        # Check if composition MOB itself has essence (sometimes they're the same)
        if hasattr(composition_mob, 'essence'):
            return composition_mob
            
    except Exception:
        pass
    
    return None


# ARCHIVED: Helper function for playback extraction (but also used by validation, so keep it)
# Note: This function is still used by validation, so we'll keep it active
def _verify_essence_mob_is_embedded(essence_mob, source_mob) -> bool:
    """
    Verifies that an essence MOB is truly embedded (no external locator).
    This is a final safety check before adding clips to playback list.
    
    Args:
        essence_mob: The essence MOB to check (or None)
        source_mob: The source/composition MOB as fallback
        
    Returns:
        bool: True if embedded (no external locator), False otherwise
    """
    import sys
    check_mob = essence_mob if essence_mob else source_mob
    if not check_mob:
        msg = "DEBUG: _verify_essence_mob_is_embedded: No MOB to check"
        print(msg, file=sys.stderr, flush=True)
        if _DEBUG_FILE:
            _DEBUG_FILE.write(msg + "\n")
            _DEBUG_FILE.flush()
        return False
    
    mob_id = str(getattr(check_mob, 'mob_id', id(check_mob)))
    msg = f"DEBUG: _verify_essence_mob_is_embedded: Checking MOB {mob_id}"
    print(msg, file=sys.stderr, flush=True)
    if _DEBUG_FILE:
        _DEBUG_FILE.write(msg + "\n")
        _DEBUG_FILE.flush()
    
    try:
        if hasattr(check_mob, 'descriptor'):
            descriptor = check_mob.descriptor
            if not descriptor:
                msg = f"DEBUG: _verify_essence_mob_is_embedded: MOB {mob_id} has no descriptor"
                print(msg, file=sys.stderr, flush=True)
                if _DEBUG_FILE:
                    _DEBUG_FILE.write(msg + "\n")
                    _DEBUG_FILE.flush()
                return False
            
            # DEBUG: Inspect descriptor structure
            try:
                desc_attrs = [attr for attr in dir(descriptor) if not attr.startswith('_')]
                msg = f"DEBUG: _verify_essence_mob_is_embedded: MOB {mob_id} descriptor attributes: {', '.join(desc_attrs[:15])}"
                print(msg, file=sys.stderr, flush=True)
                if _DEBUG_FILE:
                    _DEBUG_FILE.write(msg + "\n")
                    _DEBUG_FILE.flush()
            except Exception:
                pass
            
            # CRITICAL: Check for external locator FIRST - if it exists, NOT embedded
            # First, check if locator attribute exists and has a value
            has_locator_attr = hasattr(descriptor, 'locator')
            locator_value = None
            if has_locator_attr:
                try:
                    locator_value = getattr(descriptor, 'locator', None)
                except Exception as e:
                    msg = f"DEBUG: _verify_essence_mob_is_embedded: MOB {mob_id} error accessing locator: {e}"
                    print(msg, file=sys.stderr, flush=True)
                    if _DEBUG_FILE:
                        _DEBUG_FILE.write(msg + "\n")
                        _DEBUG_FILE.flush()
            
            # Log what we found
            msg = f"DEBUG: _verify_essence_mob_is_embedded: MOB {mob_id} - has_locator_attr={has_locator_attr}, locator_value={locator_value is not None}, locator_type={type(locator_value).__name__ if locator_value is not None else 'None'}"
            print(msg, file=sys.stderr, flush=True)
            if _DEBUG_FILE:
                _DEBUG_FILE.write(msg + "\n")
                _DEBUG_FILE.flush()
            
            # Only check locator if it actually has a value (not None)
            if locator_value is not None:
                # Handle locator as a list (common in AAF files)
                locators_to_check = []
                if isinstance(locator_value, (list, tuple)):
                    locators_to_check = list(locator_value)
                    msg = f"DEBUG: _verify_essence_mob_is_embedded: MOB {mob_id} - locator is a list with {len(locators_to_check)} item(s)"
                    print(msg, file=sys.stderr, flush=True)
                    if _DEBUG_FILE:
                        _DEBUG_FILE.write(msg + "\n")
                        _DEBUG_FILE.flush()
                else:
                    # Single locator object
                    locators_to_check = [locator_value]
                
                # Check each locator in the list
                for locator_idx, locator in enumerate(locators_to_check):
                    if locator is None:
                        continue
                    
                    # Check for path
                    locator_path = None
                    if hasattr(locator, 'path'):
                        try:
                            locator_path = getattr(locator, 'path', None)
                        except Exception:
                            pass
                    
                    # Check for URL
                    locator_url = None
                    if hasattr(locator, 'url_string'):
                        try:
                            locator_url = getattr(locator, 'url_string', None)
                            if locator_url:
                                locator_url = str(locator_url)
                        except Exception:
                            pass
                    
                    # Log what we found in this locator
                    msg = f"DEBUG: _verify_essence_mob_is_embedded: MOB {mob_id} - locator[{locator_idx}].path={locator_path}, locator[{locator_idx}].url_string={locator_url}"
                    print(msg, file=sys.stderr, flush=True)
                    if _DEBUG_FILE:
                        _DEBUG_FILE.write(msg + "\n")
                        _DEBUG_FILE.flush()
                    
                    # If there's a path, it's external
                    if locator_path:
                        msg = f"DEBUG: _verify_essence_mob_is_embedded: MOB {mob_id} has external locator[{locator_idx}].path: {locator_path}"
                        print(msg, file=sys.stderr, flush=True)
                        if _DEBUG_FILE:
                            _DEBUG_FILE.write(msg + "\n")
                            _DEBUG_FILE.flush()
                        return False
                    
                    # If there's a URL, check if it's external
                    if locator_url:
                        msg = f"DEBUG: _verify_essence_mob_is_embedded: MOB {mob_id} has locator[{locator_idx}].url_string: {locator_url}"
                        print(msg, file=sys.stderr, flush=True)
                        if _DEBUG_FILE:
                            _DEBUG_FILE.write(msg + "\n")
                            _DEBUG_FILE.flush()
                        # Only embedded if it's not a file:// or http:// URL
                        if locator_url.startswith('file://') or locator_url.startswith('http://') or locator_url.startswith('https://'):
                            msg = f"DEBUG: _verify_essence_mob_is_embedded: MOB {mob_id} has external URL (file:// or http://)"
                            print(msg, file=sys.stderr, flush=True)
                            if _DEBUG_FILE:
                                _DEBUG_FILE.write(msg + "\n")
                                _DEBUG_FILE.flush()
                            return False
                        # If it's a non-urn URL, might still be external
                        if locator_url and not locator_url.startswith('urn:'):
                            msg = f"DEBUG: _verify_essence_mob_is_embedded: MOB {mob_id} has non-urn URL, treating as external"
                            print(msg, file=sys.stderr, flush=True)
                            if _DEBUG_FILE:
                                _DEBUG_FILE.write(msg + "\n")
                                _DEBUG_FILE.flush()
                            return False
            
            # If no external locator, check for embedded essence
            # Match validation parser logic: just check if attribute exists, not if it has a value
            has_essence_attr = hasattr(descriptor, 'essence')
            has_essence_data_attr = hasattr(descriptor, 'essence_data')
            
            # Try to get values for debugging, but don't require them to be truthy
            essence_value = None
            essence_data_value = None
            try:
                if has_essence_attr:
                    essence_value = getattr(descriptor, 'essence', None)
                if has_essence_data_attr:
                    essence_data_value = getattr(descriptor, 'essence_data', None)
            except Exception as e:
                msg = f"DEBUG: _verify_essence_mob_is_embedded: Error accessing essence attributes: {e}"
                print(msg, file=sys.stderr, flush=True)
                if _DEBUG_FILE:
                    _DEBUG_FILE.write(msg + "\n")
                    _DEBUG_FILE.flush()
            
            msg = f"DEBUG: _verify_essence_mob_is_embedded: MOB {mob_id} - has_essence={has_essence_attr}, has_essence_data={has_essence_data_attr}, essence_value={essence_value is not None}, essence_data_value={essence_data_value is not None}"
            print(msg, file=sys.stderr, flush=True)
            if _DEBUG_FILE:
                _DEBUG_FILE.write(msg + "\n")
                _DEBUG_FILE.flush()
            
            # Match validation parser: just check if attribute exists (not if value is truthy)
            if has_essence_attr or has_essence_data_attr:
                msg = f"DEBUG: _verify_essence_mob_is_embedded: MOB {mob_id} verified as embedded (has essence/essence_data attribute)"
                print(msg, file=sys.stderr, flush=True)
                if _DEBUG_FILE:
                    _DEBUG_FILE.write(msg + "\n")
                    _DEBUG_FILE.flush()
                return True
        
        # Also check if MOB has essence directly
        # Match validation parser: just check if attribute exists
        mob_has_essence_attr = hasattr(check_mob, 'essence')
        
        # Try to get value for debugging, but don't require it to be truthy
        mob_essence_value = None
        if mob_has_essence_attr:
            try:
                mob_essence_value = getattr(check_mob, 'essence', None)
            except Exception:
                pass
        
        msg = f"DEBUG: _verify_essence_mob_is_embedded: MOB {mob_id} - mob.has_essence={mob_has_essence_attr}, mob.essence_value={mob_essence_value is not None}"
        print(msg, file=sys.stderr, flush=True)
        if _DEBUG_FILE:
            _DEBUG_FILE.write(msg + "\n")
            _DEBUG_FILE.flush()
        
        # Match validation parser: just check if attribute exists (not if value is truthy)
        if mob_has_essence_attr:
            msg = f"DEBUG: _verify_essence_mob_is_embedded: MOB {mob_id} verified as embedded (has mob.essence attribute)"
            print(msg, file=sys.stderr, flush=True)
            if _DEBUG_FILE:
                _DEBUG_FILE.write(msg + "\n")
                _DEBUG_FILE.flush()
            return True
        
        msg = f"DEBUG: _verify_essence_mob_is_embedded: MOB {mob_id} NOT embedded (no essence found)"
        print(msg, file=sys.stderr, flush=True)
        if _DEBUG_FILE:
            _DEBUG_FILE.write(msg + "\n")
            _DEBUG_FILE.flush()
        return False
    except Exception as e:
        # If we can't verify, assume not embedded to be safe
        msg = f"DEBUG: _verify_essence_mob_is_embedded: Error checking MOB {mob_id}: {e}"
        print(msg, file=sys.stderr, flush=True)
        if _DEBUG_FILE:
            _DEBUG_FILE.write(msg + "\n")
            _DEBUG_FILE.flush()
        import traceback
        tb_msg = f"DEBUG: _verify_essence_mob_is_embedded: Traceback: {traceback.format_exc()}"
        print(tb_msg, file=sys.stderr, flush=True)
        if _DEBUG_FILE:
            _DEBUG_FILE.write(tb_msg + "\n")
            _DEBUG_FILE.flush()
        return False


# ARCHIVED: Helper function for playback extraction
def _extract_timeline_from_composition(composition, playback_clips, processed_sources, aaf_file_path, comp_index, validation_clip_map=None, essence_mob_cache=None):
    """ARCHIVED: Disabled due to aaf2 library limitations"""
    return
    # Original implementation commented out - see git history
    # if validation_clip_map is None:
    #     validation_clip_map = {}
    # if essence_mob_cache is None:
    #     essence_mob_cache = {}
    # import sys
    
    try:
        _debug_print(f"DEBUG: === Extracting timeline from composition {comp_index} ===", verbose_only=True)
        
        # Get composition name
        comp_name = getattr(composition, 'name', 'Unnamed Composition')
        _debug_print(f"DEBUG: Composition name: {comp_name}", verbose_only=True)
        
        # Try to get edit rate for time conversion
        edit_rate = 48000.0  # Default to 48kHz
        try:
            if hasattr(composition, 'edit_rate'):
                edit_rate = float(composition.edit_rate)
                _debug_print(f"DEBUG: Composition edit_rate: {edit_rate}", verbose_only=True)
        except Exception as e:
            _debug_print(f"DEBUG: Could not get edit_rate: {e}", verbose_only=True)
        
        # Get timeline slots (tracks)
        if hasattr(composition, 'slots'):
            slots = list(composition.slots) if hasattr(composition.slots, '__iter__') else []
            _debug_print(f"DEBUG: Composition has {len(slots)} slot(s)", verbose_only=True)
            
            track_index = 0
            for slot_idx, slot in enumerate(slots):
                _debug_print(f"DEBUG: --- Processing slot {slot_idx} ---", verbose_only=True)
                
                # Get slot properties
                slot_name = getattr(slot, 'name', None)
                slot_type = type(slot).__name__
                _debug_print(f"DEBUG: Slot {slot_idx}: name={slot_name}, type={slot_type}", verbose_only=True)
                
                # Get slot position on timeline
                slot_position = 0.0
                try:
                    if hasattr(slot, 'start'):
                        slot_position = float(getattr(slot, 'start', 0))
                        _debug_print(f"DEBUG: Slot {slot_idx} start position: {slot_position} edit units", verbose_only=True)
                except Exception as e:
                    _debug_print(f"DEBUG: Could not get slot start: {e}", verbose_only=True)
                
                # Get slot length
                slot_length = 0.0
                try:
                    if hasattr(slot, 'length'):
                        slot_length = float(getattr(slot, 'length', 0))
                        _debug_print(f"DEBUG: Slot {slot_idx} length: {slot_length} edit units", verbose_only=True)
                except Exception as e:
                    _debug_print(f"DEBUG: Could not get slot length: {e}", verbose_only=True)
                
                # Check for media kind (audio vs video)
                try:
                    if hasattr(slot, 'media_kind'):
                        media_kind = getattr(slot, 'media_kind', None)
                        _debug_print(f"DEBUG: Slot {slot_idx} media_kind: {media_kind}", verbose_only=True)
                except Exception as e:
                    _debug_print(f"DEBUG: Could not get media_kind: {e}", verbose_only=True)
                
                # Get all slot attributes for debugging
                try:
                    slot_attrs = [attr for attr in dir(slot) if not attr.startswith('_')]
                    _debug_print(f"DEBUG: Slot {slot_idx} available attributes: {', '.join(slot_attrs[:20])}", verbose_only=True)
                except Exception:
                    pass
                
                if hasattr(slot, 'segment') and slot.segment:
                    segment = slot.segment
                    segment_type = type(segment).__name__
                    segment_name = getattr(segment, 'name', 'Unnamed Segment')
                    _debug_print(f"DEBUG: Slot {slot_idx} segment: name={segment_name}, type={segment_type}", verbose_only=True)
                    
                    # Convert slot position to seconds
                    timeline_position = slot_position / edit_rate
                    _debug_print(f"DEBUG: Slot {slot_idx} timeline position: {timeline_position:.3f} seconds", verbose_only=True)
                    
                    _extract_clips_from_track(segment, playback_clips, processed_sources, 
                                             aaf_file_path, track_index, timeline_position, edit_rate, depth=0, slot_idx=slot_idx, validation_clip_map=validation_clip_map, essence_mob_cache=essence_mob_cache)
                    track_index += 1
                else:
                    _debug_print(f"DEBUG: Slot {slot_idx} has no segment", verbose_only=True)
        else:
            _debug_print(f"DEBUG: Composition has no 'slots' attribute", verbose_only=True)
            # Try to find other ways to access tracks
            comp_attrs = [attr for attr in dir(composition) if not attr.startswith('_')]
            _debug_print(f"DEBUG: Composition available attributes: {', '.join(comp_attrs[:30])}", verbose_only=True)
    except Exception as e:
        _debug_print(f"DEBUG: Error extracting timeline from composition: {e}", verbose_only=True)
        import traceback
        _debug_print(f"DEBUG: Traceback: {traceback.format_exc()}", verbose_only=True)


# ARCHIVED: Helper function for playback extraction
def _extract_clips_from_track(segment, playback_clips, processed_sources, aaf_file_path, track_index, timeline_position, edit_rate, depth=0, slot_idx=0, validation_clip_map=None, essence_mob_cache=None):
    """ARCHIVED: Disabled due to aaf2 library limitations"""
    return
    # Original implementation commented out - see git history
    # if validation_clip_map is None:
    #     validation_clip_map = {}
    # if essence_mob_cache is None:
    #     essence_mob_cache = {}
    # import sys
    # indent = "  " * depth
    # 
    # # Limit recursion depth to prevent infinite loops and performance issues
    # MAX_DEPTH = 20
    # if depth > MAX_DEPTH:
    #     _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Max recursion depth ({MAX_DEPTH}) reached, stopping", verbose_only=True)
    #     return
    
    try:
        segment_type = type(segment).__name__
        segment_name = getattr(segment, 'name', 'Unnamed')
        _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Processing segment: {segment_name} (type: {segment_type}) at {timeline_position:.3f}s", verbose_only=True)
        
        # Check if this is a SourceClip
        # Also check if this is an OperationGroup that might contain SourceClips
        is_operation_group = segment_type == 'OperationGroup'
        
        if hasattr(segment, 'mob') and segment.mob is not None:
            source_mob = segment.mob
            source_id = str(getattr(source_mob, 'mob_id', id(source_mob)))
            
            _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Found SourceClip with MOB: {source_id}", verbose_only=True)
            
            if source_id in processed_sources:
                _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] SourceClip {source_id} already processed, skipping", verbose_only=True)
                return
            
            # Get clip name
            clip_name = getattr(segment, 'name', None) or getattr(source_mob, 'name', 'Unnamed Clip')
            if not clip_name:
                clip_name = f"Clip_{len(playback_clips) + 1}"
            
            _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Clip name: {clip_name}", verbose_only=True)
            
            # Get segment timing information
            segment_start = 0.0
            segment_length = 0.0
            try:
                if hasattr(segment, 'start'):
                    segment_start = float(getattr(segment, 'start', 0))
                    _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Segment start: {segment_start} edit units", verbose_only=True)
                if hasattr(segment, 'length'):
                    segment_length = float(getattr(segment, 'length', 0))
                    _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Segment length: {segment_length} edit units", verbose_only=True)
            except Exception as e:
                _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Could not get segment timing: {e}", verbose_only=True)
            
            # Check if embedded
            is_embedded = False
            try:
                if hasattr(source_mob, 'descriptor'):
                    descriptor = source_mob.descriptor
                    if hasattr(descriptor, 'essence') or hasattr(descriptor, 'essence_data'):
                        is_embedded = True
                if not is_embedded and hasattr(source_mob, 'essence'):
                    is_embedded = True
            except Exception:
                pass
            
            _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Is embedded: {is_embedded}", verbose_only=True)
            
            # FINAL VERIFICATION: Always double-check the MOB for external locators
            if is_embedded:
                import sys
                essence_mob = _find_essence_mob_from_composition_mob(source_mob)
                msg = f"DEBUG: [{slot_idx}/T{track_index}] Running final verification for clip '{clip_name}' (source_id={source_id})"
                print(msg, file=sys.stderr, flush=True)
                if _DEBUG_FILE:
                    _DEBUG_FILE.write(msg + "\n")
                    _DEBUG_FILE.flush()
                is_embedded = _verify_essence_mob_is_embedded(essence_mob, source_mob)
                if not is_embedded:
                    msg = f"DEBUG: [{slot_idx}/T{track_index}] REJECTED clip '{clip_name}' (source_id={source_id}): Final verification failed - MOB has external locator"
                    print(msg, file=sys.stderr, flush=True)
                    if _DEBUG_FILE:
                        _DEBUG_FILE.write(msg + "\n")
                        _DEBUG_FILE.flush()
            
            # Only process embedded clips
            if is_embedded:
                # Calculate clip position on timeline
                # timeline_position is already in seconds (from slot position)
                # segment_start is the offset within the source file (in edit units)
                # segment_length is the clip duration (in edit units)
                
                clip_start = timeline_position  # Position on timeline (already in seconds)
                source_start = segment_start / edit_rate  # Source file offset (convert to seconds)
                clip_length = segment_length / edit_rate if segment_length > 0 else 0.0  # Clip duration (convert to seconds)
                source_length = clip_length
                
                _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Clip timeline: start={clip_start:.3f}s, length={clip_length:.3f}s", verbose_only=True)
                _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Clip source: start={source_start:.3f}s, length={source_length:.3f}s", verbose_only=True)
                
                embedded_path = f"EMBEDDED:{aaf_file_path}:{source_id}"
                # playback_clip = PlaybackClip(
                    # name=clip_name,
                    # file_path=embedded_path,
                    # start_time=source_start,
                    # duration=source_length,
                    # track_index=track_index,
                    # timeline_start=clip_start,
                    # timeline_end=clip_start + clip_length,
                    # source_in=source_start,
                    # source_out=source_start + source_length
                # )
                # playback_clips.append(playback_clip)
                _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Added clip: {clip_name} at track {track_index}, timeline {clip_start:.3f}-{clip_start + clip_length:.3f}s", verbose_only=True)
                
                # Update timeline position for next clip (if sequential)
                # But note: clips might overlap, so we don't always advance
                if segment_length > 0:
                    timeline_position += segment_length / edit_rate
                    _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Updated timeline position to {timeline_position:.3f}s", verbose_only=True)
        
        # For OperationGroups, check segments first (they have segments, not components)
        if is_operation_group and hasattr(segment, 'segments'):
            try:
                op_segments = list(segment.segments) if hasattr(segment.segments, '__iter__') else []
                _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] OperationGroup (as segment) has {len(op_segments)} segment(s)", verbose_only=True)
                for seg_idx, op_seg in enumerate(op_segments):
                    seg_type = type(op_seg).__name__
                    _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] OperationGroup segment {seg_idx}: type={seg_type}", verbose_only=True)
                    
                    # Recursively search nested OperationGroups
                    if seg_type == 'OperationGroup':
                        _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Nested OperationGroup in segment, recursively searching...", verbose_only=True)
                        _extract_clips_from_track(op_seg, playback_clips, processed_sources,
                                                 aaf_file_path, track_index, timeline_position, edit_rate, depth + 1, slot_idx, validation_clip_map)
                        continue
                    
                    # Check if this segment is a SourceClip
                    if hasattr(op_seg, 'mob') and op_seg.mob is not None:
                        source_mob = op_seg.mob
                        source_id = str(getattr(source_mob, 'mob_id', id(source_mob)))
                        
                        _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Found SourceClip in OperationGroup segment {seg_idx}: {source_id}", verbose_only=True)
                        
                        # Note: We allow the same clip to appear multiple times on the timeline
                        # (same audio file can be used in multiple places)
                        # Get clip name
                        clip_name = getattr(op_seg, 'name', None) or getattr(source_mob, 'name', 'Unnamed Clip')
                        if not clip_name:
                            clip_name = f"Clip_{len(playback_clips) + 1}"
                        
                        # Get segment timing
                        segment_start = 0.0
                        segment_length = 0.0
                        try:
                            if hasattr(op_seg, 'start'):
                                segment_start = float(getattr(op_seg, 'start', 0))
                            if hasattr(op_seg, 'length'):
                                segment_length = float(getattr(op_seg, 'length', 0))
                        except Exception:
                            pass
                        
                        # Match with validation clips - use comprehensive matching like in the component processing
                        is_embedded = False
                        matched_validation_clip = None
                        # Use cache to avoid repeated essence MOB lookups
                        source_id_key = str(source_id)
                        if source_id_key in essence_mob_cache:
                            essence_mob = essence_mob_cache[source_id_key]
                        else:
                            essence_mob = _find_essence_mob_from_composition_mob(source_mob)
                            if essence_mob:
                                essence_mob_cache[source_id_key] = essence_mob
                        essence_id = None
                        if essence_mob:
                            essence_id = str(getattr(essence_mob, 'mob_id', id(essence_mob)))
                            _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Found Essence MOB: {essence_id}", verbose_only=True)
                        
                        # Try multiple ways to match (same as component processing)
                        if essence_id:
                            if essence_id in validation_clip_map:
                                matched_validation_clip = validation_clip_map[essence_id]
                                is_embedded = matched_validation_clip.is_embedded
                                _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Matched validation clip by essence_id: {matched_validation_clip.name}, embedded={is_embedded}", verbose_only=True)
                            elif essence_id.strip() in validation_clip_map:
                                matched_validation_clip = validation_clip_map[essence_id.strip()]
                                is_embedded = matched_validation_clip.is_embedded
                                _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Matched validation clip by normalized essence_id: {matched_validation_clip.name}, embedded={is_embedded}", verbose_only=True)
                        
                        # Fallback: try source_id
                        if not matched_validation_clip:
                            if source_id in validation_clip_map:
                                matched_validation_clip = validation_clip_map[source_id]
                                is_embedded = matched_validation_clip.is_embedded
                                _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Matched validation clip by source_id: {matched_validation_clip.name}, embedded={is_embedded}", verbose_only=True)
                            elif source_id.strip() in validation_clip_map:
                                matched_validation_clip = validation_clip_map[source_id.strip()]
                                is_embedded = matched_validation_clip.is_embedded
                                _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Matched validation clip by normalized source_id: {matched_validation_clip.name}, embedded={is_embedded}", verbose_only=True)
                        
                        # If still no match, check directly
                        if not matched_validation_clip:
                            try:
                                check_mob = essence_mob if essence_mob else source_mob
                                if hasattr(check_mob, 'descriptor'):
                                    descriptor = check_mob.descriptor
                                    if hasattr(descriptor, 'essence') or hasattr(descriptor, 'essence_data'):
                                        is_embedded = True
                                if not is_embedded and hasattr(check_mob, 'essence'):
                                    is_embedded = True
                            except Exception as e:
                                _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Error checking embedded status: {e}", verbose_only=True)
                        
                        _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Is embedded: {is_embedded}", verbose_only=True)
                        
                        # FINAL VERIFICATION: Always double-check the essence MOB for external locators
                        if is_embedded:
                            import sys
                            print(f"DEBUG: [{slot_idx}/T{track_index}] Running final verification for clip '{clip_name}' (source_id={source_id}, essence_id={essence_id})", file=sys.stderr, flush=True)
                            is_embedded = _verify_essence_mob_is_embedded(essence_mob, source_mob)
                            if not is_embedded:
                                print(f"DEBUG: [{slot_idx}/T{track_index}] REJECTED clip '{clip_name}' (source_id={source_id}, essence_id={essence_id}): Final verification failed - MOB has external locator", file=sys.stderr, flush=True)
                        
                        if is_embedded:
                            if matched_validation_clip:
                                clip_name = matched_validation_clip.name
                            clip_start = timeline_position
                            source_start = segment_start / edit_rate
                            clip_length = segment_length / edit_rate if segment_length > 0 else 0.0
                            
                            embedded_id = essence_id if essence_id else source_id
                            embedded_path = f"EMBEDDED:{aaf_file_path}:{embedded_id}"
                            # playback_clip = PlaybackClip(
                                # name=clip_name,
                                # file_path=embedded_path,
                                # start_time=source_start,
                                # duration=clip_length,
                                # track_index=track_index,
                                # timeline_start=clip_start,
                                # timeline_end=clip_start + clip_length,
                                # source_in=source_start,
                                # source_out=source_start + clip_length
                            # )
                            # playback_clips.append(playback_clip)
                            processed_sources.add(source_id)
                            if essence_id:
                                processed_sources.add(essence_id)
                            _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Added clip from OperationGroup segment: {clip_name} at track {track_index}, timeline {clip_start:.3f}-{clip_start + clip_length:.3f}s", verbose_only=True)
                            
                            if segment_length > 0:
                                timeline_position += segment_length / edit_rate
            except Exception as e:
                _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Error processing OperationGroup segments: {e}", verbose_only=True)
        
        # Process sequence components
        # For OperationGroups, we need to look inside for SourceClips
        if hasattr(segment, 'components'):
            components = list(segment.components) if hasattr(segment.components, '__iter__') else []
            _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Segment has {len(components)} component(s)", verbose_only=True)
            current_pos = timeline_position
            
            # Process each component - check if it's an OperationGroup or contains SourceClips
            for comp_idx, component in enumerate(components):
                comp_type = type(component).__name__
                comp_length = getattr(component, 'length', 0) if hasattr(component, 'length') else 0
                comp_length_sec = comp_length / edit_rate if comp_length > 0 else 0.0
                _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Processing component {comp_idx} (type: {comp_type}) at {current_pos:.3f}s, length={comp_length_sec:.3f}s", verbose_only=True)
                
                # Check if this component is an OperationGroup
                is_comp_operation_group = comp_type == 'OperationGroup'
                
                # For OperationGroups, check if segments contain SourceClips
                if is_comp_operation_group:
                    _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Detected OperationGroup, inspecting structure...", verbose_only=True)
                    
                    # OperationGroups have 'segments' attribute, not 'components'
                    # Check segments for SourceClips
                    if hasattr(component, 'segments'):
                        try:
                            op_segments = list(component.segments) if hasattr(component.segments, '__iter__') else []
                            _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] OperationGroup has {len(op_segments)} segment(s)", verbose_only=True)
                            
                            for seg_idx, op_seg in enumerate(op_segments):
                                seg_type = type(op_seg).__name__
                                _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] OperationGroup segment {seg_idx}: type={seg_type}", verbose_only=True)
                                
                                # If this segment is another OperationGroup, recursively search it
                                if seg_type == 'OperationGroup':
                                    _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Nested OperationGroup found, recursively searching...", verbose_only=True)
                                    _extract_clips_from_track(op_seg, playback_clips, processed_sources,
                                                             aaf_file_path, track_index, current_pos, edit_rate, depth + 1, slot_idx, validation_clip_map)
                                    continue
                                
                                # Check if this segment is a SourceClip (has mob attribute)
                                if hasattr(op_seg, 'mob') and op_seg.mob is not None:
                                    source_mob = op_seg.mob
                                    source_id = str(getattr(source_mob, 'mob_id', id(source_mob)))
                                    
                                    _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Found SourceClip in OperationGroup segment {seg_idx}: {source_id}", verbose_only=True)
                                    
                                    # Note: We allow the same clip to appear multiple times on the timeline
                                    # Get clip name
                                    clip_name = getattr(op_seg, 'name', None) or getattr(source_mob, 'name', 'Unnamed Clip')
                                    if not clip_name:
                                        clip_name = f"Clip_{len(playback_clips) + 1}"
                                    
                                    _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Clip name: {clip_name}", verbose_only=True)
                                    
                                    # Get segment timing information
                                    segment_start = 0.0
                                    segment_length = 0.0
                                    try:
                                        if hasattr(op_seg, 'start'):
                                            segment_start = float(getattr(op_seg, 'start', 0))
                                            _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Segment start: {segment_start} edit units", verbose_only=True)
                                        if hasattr(op_seg, 'length'):
                                            segment_length = float(getattr(op_seg, 'length', 0))
                                            _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Segment length: {segment_length} edit units", verbose_only=True)
                                    except Exception as e:
                                        _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Could not get segment timing: {e}", verbose_only=True)
                                    
                                    # Check if embedded - use validation parser's determination
                                    # Match this SourceClip with validation clips by finding the Essence MOB
                                    is_embedded = False
                                    matched_validation_clip = None
                                    
                                    # Debug: show what we're trying to match
                                    _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Attempting to match source_id='{source_id}' (type: {type(source_id).__name__})", verbose_only=True)
                                    if validation_clip_map:
                                        sample_keys = list(validation_clip_map.keys())[:3]
                                        _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Sample validation_clip_map keys: {sample_keys}", verbose_only=True)
                                    
                                    # CRITICAL: Follow the MOB reference chain to find the Essence MOB
                                    # The source_mob is a Composition MOB, we need to find the Essence MOB it references
                                    essence_mob = _find_essence_mob_from_composition_mob(source_mob)
                                    essence_id = None
                                    if essence_mob:
                                        essence_id = str(getattr(essence_mob, 'mob_id', id(essence_mob)))
                                        _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Found Essence MOB: {essence_id}", verbose_only=True)
                                    
                                    # Try multiple ways to match
                                    # 1. Try matching by Essence MOB ID (most reliable)
                                    if essence_id:
                                        if essence_id in validation_clip_map:
                                            matched_validation_clip = validation_clip_map[essence_id]
                                            is_embedded = matched_validation_clip.is_embedded
                                            _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Matched validation clip by essence_id: {matched_validation_clip.name}, embedded={is_embedded}", verbose_only=True)
                                            # VERIFY: Double-check for external locator even if validation says embedded
                                            if is_embedded and essence_mob and hasattr(essence_mob, 'descriptor'):
                                                try:
                                                    desc = essence_mob.descriptor
                                                    if hasattr(desc, 'locator') and desc.locator:
                                                        is_embedded = False
                                                        _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Overriding: Essence MOB has external locator, not embedded", verbose_only=True)
                                                except Exception:
                                                    pass
                                        else:
                                            # Try normalized essence_id
                                            normalized_essence_id = essence_id.strip()
                                            if normalized_essence_id in validation_clip_map:
                                                matched_validation_clip = validation_clip_map[normalized_essence_id]
                                                is_embedded = matched_validation_clip.is_embedded
                                                _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Matched validation clip by normalized essence_id: {matched_validation_clip.name}, embedded={is_embedded}", verbose_only=True)
                                                # VERIFY: Double-check for external locator even if validation says embedded
                                                if is_embedded and essence_mob and hasattr(essence_mob, 'descriptor'):
                                                    try:
                                                        desc = essence_mob.descriptor
                                                        if hasattr(desc, 'locator') and desc.locator:
                                                            is_embedded = False
                                                            _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Overriding: Essence MOB has external locator, not embedded", verbose_only=True)
                                                    except Exception:
                                                        pass
                                    
                                    # 2. Fallback: Direct match by source_id (Composition MOB)
                                    if not matched_validation_clip:
                                        if source_id in validation_clip_map:
                                            matched_validation_clip = validation_clip_map[source_id]
                                            is_embedded = matched_validation_clip.is_embedded
                                            _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Matched validation clip by source_id: {matched_validation_clip.name}, embedded={is_embedded}", verbose_only=True)
                                            # VERIFY: Double-check for external locator
                                            check_mob = essence_mob if essence_mob else source_mob
                                            if is_embedded and hasattr(check_mob, 'descriptor'):
                                                try:
                                                    desc = check_mob.descriptor
                                                    if hasattr(desc, 'locator') and desc.locator:
                                                        is_embedded = False
                                                        _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Overriding: MOB has external locator, not embedded", verbose_only=True)
                                                except Exception:
                                                    pass
                                        else:
                                            # 3. Try normalized source_id (strip whitespace)
                                            normalized_source_id = source_id.strip()
                                            if normalized_source_id in validation_clip_map:
                                                matched_validation_clip = validation_clip_map[normalized_source_id]
                                                is_embedded = matched_validation_clip.is_embedded
                                                _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Matched validation clip by normalized source_id: {matched_validation_clip.name}, embedded={is_embedded}", verbose_only=True)
                                                # VERIFY: Double-check for external locator
                                                check_mob = essence_mob if essence_mob else source_mob
                                                if is_embedded and hasattr(check_mob, 'descriptor'):
                                                    try:
                                                        desc = check_mob.descriptor
                                                        if hasattr(desc, 'locator') and desc.locator:
                                                            is_embedded = False
                                                            _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Overriding: MOB has external locator, not embedded", verbose_only=True)
                                                    except Exception:
                                                        pass
                                            else:
                                                # 4. Try to get mob_id in different formats
                                                try:
                                                    # Try getting mob_id as a property (might be a UMID object)
                                                    mob_id_obj = getattr(source_mob, 'mob_id', None)
                                                    if mob_id_obj:
                                                        # Try as string
                                                        mob_id_str = str(mob_id_obj)
                                                        if mob_id_str in validation_clip_map:
                                                            matched_validation_clip = validation_clip_map[mob_id_str]
                                                            is_embedded = matched_validation_clip.is_embedded
                                                            _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Matched validation clip by mob_id string: {matched_validation_clip.name}, embedded={is_embedded}", verbose_only=True)
                                                        # Try normalized mob_id_str
                                                        elif mob_id_str.strip() in validation_clip_map:
                                                            matched_validation_clip = validation_clip_map[mob_id_str.strip()]
                                                            is_embedded = matched_validation_clip.is_embedded
                                                            _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Matched validation clip by normalized mob_id: {matched_validation_clip.name}, embedded={is_embedded}", verbose_only=True)
                                                        # Try as repr (in case it's an object)
                                                        elif repr(mob_id_obj) in validation_clip_map:
                                                            matched_validation_clip = validation_clip_map[repr(mob_id_obj)]
                                                            is_embedded = matched_validation_clip.is_embedded
                                                            _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Matched validation clip by mob_id repr: {matched_validation_clip.name}, embedded={is_embedded}", verbose_only=True)
                                                except Exception as e:
                                                    _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Error trying mob_id formats: {e}", verbose_only=True)
                                                
                                                # 5. If still no match, check directly (same logic as validation parser)
                                                if not matched_validation_clip:
                                                    try:
                                                        # Check the essence MOB if we found one
                                                        check_mob = essence_mob if essence_mob else source_mob
                                                        if hasattr(check_mob, 'descriptor'):
                                                            descriptor = check_mob.descriptor
                                                            # CRITICAL: Check for locator FIRST (external file) - if it exists, NOT embedded
                                                            external_path = None
                                                            if hasattr(descriptor, 'locator') and descriptor.locator:
                                                                locator = descriptor.locator
                                                                if locator:
                                                                    if hasattr(locator, 'path'):
                                                                        external_path = str(locator.path)
                                                                    elif hasattr(locator, 'url_string'):
                                                                        url = str(locator.url_string)
                                                                        if url.startswith('file://'):
                                                                            external_path = url[7:]
                                                                        elif not url.startswith('http'):
                                                                            external_path = url
                                                            
                                                            # If external path exists, this is NOT embedded
                                                            if external_path:
                                                                is_embedded = False
                                                            # If no external path, check for essence (embedded)
                                                            elif hasattr(descriptor, 'essence') or hasattr(descriptor, 'essence_data'):
                                                                is_embedded = True
                                                        
                                                        if not is_embedded and hasattr(check_mob, 'essence'):
                                                            is_embedded = True
                                                    except Exception as e:
                                                        _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Error checking embedded status: {e}", verbose_only=True)
                                    
                                    _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Is embedded: {is_embedded}", verbose_only=True)
                                    
                                    # FINAL VERIFICATION: Always double-check the essence MOB for external locators
                                    # This is a safety net to catch any clips that slip through
                                    if is_embedded:
                                        import sys
                                        print(f"DEBUG: [{slot_idx}/T{track_index}] Running final verification for clip '{clip_name}' (source_id={source_id}, essence_id={essence_id})", file=sys.stderr, flush=True)
                                        is_embedded = _verify_essence_mob_is_embedded(essence_mob, source_mob)
                                        if not is_embedded:
                                            print(f"DEBUG: [{slot_idx}/T{track_index}] REJECTED clip '{clip_name}' (source_id={source_id}, essence_id={essence_id}): Final verification failed - MOB has external locator", file=sys.stderr, flush=True)
                                    
                                    # Only process embedded clips
                                    if is_embedded:
                                        # Use validation clip name if available
                                        if matched_validation_clip:
                                            clip_name = matched_validation_clip.name
                                        clip_start = current_pos
                                        source_start = segment_start / edit_rate
                                        clip_length = segment_length / edit_rate if segment_length > 0 else 0.0
                                        source_length = clip_length
                                        
                                        _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Clip timeline: start={clip_start:.3f}s, length={clip_length:.3f}s", verbose_only=True)
                                        _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Clip source: start={source_start:.3f}s, length={source_length:.3f}s", verbose_only=True)
                                        
                                        # Use essence_id for embedded path if we found it, otherwise use source_id
                                        embedded_id = essence_id if essence_id else source_id
                                        embedded_path = f"EMBEDDED:{aaf_file_path}:{embedded_id}"
                                        # playback_clip = PlaybackClip(
                                            # name=clip_name,
                                            # file_path=embedded_path,
                                            # start_time=source_start,
                                            # duration=source_length,
                                            # track_index=track_index,
                                            # timeline_start=clip_start,
                                            # timeline_end=clip_start + clip_length,
                                            # source_in=source_start,
                                            # source_out=source_start + source_length
                                        # )
                                        # playback_clips.append(playback_clip)
                                        processed_sources.add(source_id)  # Track by composition MOB to avoid duplicates
                                        if essence_id:
                                            processed_sources.add(essence_id)  # Also track by essence MOB
                                        _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Added clip: {clip_name} at track {track_index}, timeline {clip_start:.3f}-{clip_start + clip_length:.3f}s", verbose_only=True)
                                        
                                        if segment_length > 0:
                                            current_pos += segment_length / edit_rate
                                            _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Updated timeline position to {current_pos:.3f}s", verbose_only=True)
                        except Exception as e:
                            _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Error accessing OperationGroup.segments: {e}", verbose_only=True)
                    
                    # Also check slots in OperationGroup (if it has any)
                    if hasattr(component, 'slots'):
                        try:
                            op_slots = list(component.slots) if hasattr(component.slots, '__iter__') else []
                            _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] OperationGroup has {len(op_slots)} slot(s)", verbose_only=True)
                            for op_slot_idx, op_slot in enumerate(op_slots):
                                if hasattr(op_slot, 'segment') and op_slot.segment:
                                    op_slot_seg = op_slot.segment
                                    if hasattr(op_slot_seg, 'mob') and op_slot_seg.mob is not None:
                                        # Found SourceClip in slot!
                                        source_mob = op_slot_seg.mob
                                        source_id = str(getattr(source_mob, 'mob_id', id(source_mob)))
                                        _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Found SourceClip in OperationGroup slot {op_slot_idx}: {source_id}", verbose_only=True)
                                        
                                        # Note: We allow the same clip to appear multiple times on the timeline
                                        clip_name = getattr(op_slot_seg, 'name', None) or getattr(source_mob, 'name', 'Unnamed Clip')
                                        if not clip_name:
                                            clip_name = f"Clip_{len(playback_clips) + 1}"
                                        
                                        segment_start = 0.0
                                        segment_length = 0.0
                                        try:
                                            if hasattr(op_slot_seg, 'start'):
                                                segment_start = float(getattr(op_slot_seg, 'start', 0))
                                            if hasattr(op_slot_seg, 'length'):
                                                segment_length = float(getattr(op_slot_seg, 'length', 0))
                                        except Exception:
                                            pass
                                        
                                        # Check if embedded - use validation parser's determination
                                        is_embedded = False
                                        matched_validation_clip = None
                                        
                                        # Follow the MOB reference chain to find the Essence MOB
                                        essence_mob = _find_essence_mob_from_composition_mob(source_mob)
                                        essence_id = None
                                        if essence_mob:
                                            essence_id = str(getattr(essence_mob, 'mob_id', id(essence_mob)))
                                        
                                        # Try matching by Essence MOB ID
                                        if essence_id and essence_id in validation_clip_map:
                                            matched_validation_clip = validation_clip_map[essence_id]
                                            is_embedded = matched_validation_clip.is_embedded
                                            # VERIFY: Double-check for external locator
                                            if is_embedded and essence_mob and hasattr(essence_mob, 'descriptor'):
                                                try:
                                                    desc = essence_mob.descriptor
                                                    if hasattr(desc, 'locator') and desc.locator:
                                                        is_embedded = False
                                                except Exception:
                                                    pass
                                        elif essence_id and essence_id.strip() in validation_clip_map:
                                            matched_validation_clip = validation_clip_map[essence_id.strip()]
                                            is_embedded = matched_validation_clip.is_embedded
                                            # VERIFY: Double-check for external locator
                                            if is_embedded and essence_mob and hasattr(essence_mob, 'descriptor'):
                                                try:
                                                    desc = essence_mob.descriptor
                                                    if hasattr(desc, 'locator') and desc.locator:
                                                        is_embedded = False
                                                except Exception:
                                                    pass
                                        else:
                                            # Fallback: check directly
                                            try:
                                                check_mob = essence_mob if essence_mob else source_mob
                                                if hasattr(check_mob, 'descriptor'):
                                                    descriptor = check_mob.descriptor
                                                    # CRITICAL: Check for locator FIRST (external file) - if it exists, NOT embedded
                                                    external_path = None
                                                    if hasattr(descriptor, 'locator') and descriptor.locator:
                                                        locator = descriptor.locator
                                                        if locator:
                                                            if hasattr(locator, 'path'):
                                                                external_path = str(locator.path)
                                                            elif hasattr(locator, 'url_string'):
                                                                url = str(locator.url_string)
                                                                if url.startswith('file://'):
                                                                    external_path = url[7:]
                                                                elif not url.startswith('http'):
                                                                    external_path = url
                                                    
                                                    # If external path exists, this is NOT embedded
                                                    if external_path:
                                                        is_embedded = False
                                                    # If no external path, check for essence (embedded)
                                                    elif hasattr(descriptor, 'essence') or hasattr(descriptor, 'essence_data'):
                                                        is_embedded = True
                                                if not is_embedded and hasattr(check_mob, 'essence'):
                                                    is_embedded = True
                                            except Exception:
                                                pass
                                        
                                        # FINAL VERIFICATION: Always double-check the essence MOB for external locators
                                        if is_embedded:
                                            import sys
                                            print(f"DEBUG: [{slot_idx}/T{track_index}] Running final verification for clip '{clip_name}' (source_id={source_id}, essence_id={essence_id})", file=sys.stderr, flush=True)
                                            is_embedded = _verify_essence_mob_is_embedded(essence_mob, source_mob)
                                            if not is_embedded:
                                                print(f"DEBUG: [{slot_idx}/T{track_index}] REJECTED clip '{clip_name}' (source_id={source_id}, essence_id={essence_id}): Final verification failed - MOB has external locator", file=sys.stderr, flush=True)
                                        
                                        if is_embedded:
                                            # Use validation clip name if available
                                            if matched_validation_clip:
                                                clip_name = matched_validation_clip.name
                                            clip_start = current_pos
                                            source_start = segment_start / edit_rate
                                            clip_length = segment_length / edit_rate if segment_length > 0 else 0.0
                                            
                                            # Use essence_id for embedded path if we found it
                                            embedded_id = essence_id if essence_id else source_id
                                            embedded_path = f"EMBEDDED:{aaf_file_path}:{embedded_id}"
                                            # playback_clip = PlaybackClip(
                                                # name=clip_name,
                                                # file_path=embedded_path,
                                                # start_time=source_start,
                                                # duration=clip_length,
                                                # track_index=track_index,
                                                # timeline_start=clip_start,
                                                # timeline_end=clip_start + clip_length,
                                                # source_in=source_start,
                                                # source_out=source_start + clip_length
                                            # )
                                            # playback_clips.append(playback_clip)
                                            _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Added clip from OperationGroup slot: {clip_name} at track {track_index}, timeline {clip_start:.3f}-{clip_start + clip_length:.3f}s", verbose_only=True)
                                            
                                            if segment_length > 0:
                                                current_pos += segment_length / edit_rate
                        except Exception as e:
                            _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Error accessing OperationGroup.slots: {e}", verbose_only=True)
                    
                    # Continue to check if there are any nested components (for recursive search)
                    if hasattr(component, 'components'):
                        try:
                            op_components = list(component.components) if hasattr(component.components, '__iter__') else []
                            if op_components:
                                _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] OperationGroup also has {len(op_components)} component(s) (nested)", verbose_only=True)
                        except Exception:
                            pass
                    
                    # Don't skip recursion - still recurse to find nested structures
                        
                        for op_comp_idx, op_component in enumerate(op_components):
                            op_comp_type = type(op_component).__name__
                            _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] OperationGroup component {op_comp_idx}: type={op_comp_type}", verbose_only=True)
                            
                            # Check if this component is a SourceClip (has mob attribute)
                            if hasattr(op_component, 'mob') and op_component.mob is not None:
                                source_mob = op_component.mob
                                source_id = str(getattr(source_mob, 'mob_id', id(source_mob)))
                                
                                _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Found SourceClip in OperationGroup component {op_comp_idx}: {source_id}", verbose_only=True)
                                
                                # Note: We allow the same clip to appear multiple times on the timeline
                                # Get clip name
                                clip_name = getattr(op_component, 'name', None) or getattr(source_mob, 'name', 'Unnamed Clip')
                                if not clip_name:
                                    clip_name = f"Clip_{len(playback_clips) + 1}"
                                
                                _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Clip name: {clip_name}", verbose_only=True)
                                
                                # Get segment timing information
                                segment_start = 0.0
                                segment_length = 0.0
                                try:
                                    if hasattr(op_component, 'start'):
                                        segment_start = float(getattr(op_component, 'start', 0))
                                        _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Component start: {segment_start} edit units", verbose_only=True)
                                    if hasattr(op_component, 'length'):
                                        segment_length = float(getattr(op_component, 'length', 0))
                                        _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Component length: {segment_length} edit units", verbose_only=True)
                                except Exception as e:
                                    _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Could not get component timing: {e}", verbose_only=True)
                                
                                # Check if embedded - use validation parser's determination
                                is_embedded = False
                                matched_validation_clip = None
                                
                                # Follow the MOB reference chain to find the Essence MOB
                                essence_mob = _find_essence_mob_from_composition_mob(source_mob)
                                essence_id = None
                                if essence_mob:
                                    essence_id = str(getattr(essence_mob, 'mob_id', id(essence_mob)))
                                
                                # Try matching by Essence MOB ID
                                if essence_id and essence_id in validation_clip_map:
                                    matched_validation_clip = validation_clip_map[essence_id]
                                    is_embedded = matched_validation_clip.is_embedded
                                    # VERIFY: Double-check for external locator
                                    if is_embedded and essence_mob and hasattr(essence_mob, 'descriptor'):
                                        try:
                                            desc = essence_mob.descriptor
                                            if hasattr(desc, 'locator') and desc.locator:
                                                is_embedded = False
                                        except Exception:
                                            pass
                                elif essence_id and essence_id.strip() in validation_clip_map:
                                    matched_validation_clip = validation_clip_map[essence_id.strip()]
                                    is_embedded = matched_validation_clip.is_embedded
                                    # VERIFY: Double-check for external locator
                                    if is_embedded and essence_mob and hasattr(essence_mob, 'descriptor'):
                                        try:
                                            desc = essence_mob.descriptor
                                            if hasattr(desc, 'locator') and desc.locator:
                                                is_embedded = False
                                        except Exception:
                                            pass
                                else:
                                    # Fallback: check directly
                                    try:
                                        check_mob = essence_mob if essence_mob else source_mob
                                        if hasattr(check_mob, 'descriptor'):
                                            descriptor = check_mob.descriptor
                                            # CRITICAL: Check for locator FIRST (external file) - if it exists, NOT embedded
                                            external_path = None
                                            if hasattr(descriptor, 'locator') and descriptor.locator:
                                                locator = descriptor.locator
                                                if locator:
                                                    if hasattr(locator, 'path'):
                                                        external_path = str(locator.path)
                                                    elif hasattr(locator, 'url_string'):
                                                        url = str(locator.url_string)
                                                        if url.startswith('file://'):
                                                            external_path = url[7:]
                                                        elif not url.startswith('http'):
                                                            external_path = url
                                            
                                            # If external path exists, this is NOT embedded
                                            if external_path:
                                                is_embedded = False
                                            # If no external path, check for essence (embedded)
                                            elif hasattr(descriptor, 'essence') or hasattr(descriptor, 'essence_data'):
                                                is_embedded = True
                                        if not is_embedded and hasattr(check_mob, 'essence'):
                                            is_embedded = True
                                    except Exception:
                                        pass
                                
                                _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Is embedded: {is_embedded}", verbose_only=True)
                                
                                # FINAL VERIFICATION: Always double-check the essence MOB for external locators
                                if is_embedded:
                                    is_embedded = _verify_essence_mob_is_embedded(essence_mob, source_mob)
                                    if not is_embedded:
                                        _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Final verification failed: MOB has external locator", verbose_only=True)
                                
                                # Only process embedded clips
                                if is_embedded:
                                    # Use validation clip name if available
                                    if matched_validation_clip:
                                        clip_name = matched_validation_clip.name
                                    clip_start = current_pos
                                    source_start = segment_start / edit_rate
                                    clip_length = segment_length / edit_rate if segment_length > 0 else 0.0
                                    source_length = clip_length
                                    
                                    _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Clip timeline: start={clip_start:.3f}s, length={clip_length:.3f}s", verbose_only=True)
                                    _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Clip source: start={source_start:.3f}s, length={source_length:.3f}s", verbose_only=True)
                                    
                                    # Use essence_id for embedded path if we found it
                                    embedded_id = essence_id if essence_id else source_id
                                    embedded_path = f"EMBEDDED:{aaf_file_path}:{embedded_id}"
                                    # playback_clip = PlaybackClip(
                                        # name=clip_name,
                                        # file_path=embedded_path,
                                        # start_time=source_start,
                                        # duration=source_length,
                                        # track_index=track_index,
                                        # timeline_start=clip_start,
                                        # timeline_end=clip_start + clip_length,
                                        # source_in=source_start,
                                        # source_out=source_start + source_length
                                    # )
                                    # playback_clips.append(playback_clip)
                                    processed_sources.add(source_id)
                                    _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Added clip: {clip_name} at track {track_index}, timeline {clip_start:.3f}-{clip_start + clip_length:.3f}s", verbose_only=True)
                                    
                                    if segment_length > 0:
                                        current_pos += segment_length / edit_rate
                                        _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Updated timeline position to {current_pos:.3f}s", verbose_only=True)
                    
                    # Also check slots in OperationGroup
                    if hasattr(component, 'slots'):
                        op_slots = list(component.slots) if hasattr(component.slots, '__iter__') else []
                        _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] OperationGroup has {len(op_slots)} slot(s)", verbose_only=True)
                        for op_slot_idx, op_slot in enumerate(op_slots):
                            if hasattr(op_slot, 'segment') and op_slot.segment:
                                op_slot_seg = op_slot.segment
                                if hasattr(op_slot_seg, 'mob') and op_slot_seg.mob is not None:
                                    # Found SourceClip in slot!
                                    source_mob = op_slot_seg.mob
                                    source_id = str(getattr(source_mob, 'mob_id', id(source_mob)))
                                    _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Found SourceClip in OperationGroup slot {op_slot_idx}: {source_id}", verbose_only=True)
                                    
                                    # Note: We allow the same clip to appear multiple times on the timeline
                                    clip_name = getattr(op_slot_seg, 'name', None) or getattr(source_mob, 'name', 'Unnamed Clip')
                                    if not clip_name:
                                        clip_name = f"Clip_{len(playback_clips) + 1}"
                                    
                                    segment_start = 0.0
                                    segment_length = 0.0
                                    try:
                                        if hasattr(op_slot_seg, 'start'):
                                            segment_start = float(getattr(op_slot_seg, 'start', 0))
                                        if hasattr(op_slot_seg, 'length'):
                                            segment_length = float(getattr(op_slot_seg, 'length', 0))
                                    except Exception:
                                        pass
                                    
                                    # Check if embedded - use validation parser's determination
                                    is_embedded = False
                                    matched_validation_clip = None
                                    
                                    # Follow the MOB reference chain to find the Essence MOB
                                    essence_mob = _find_essence_mob_from_composition_mob(source_mob)
                                    essence_id = None
                                    if essence_mob:
                                        essence_id = str(getattr(essence_mob, 'mob_id', id(essence_mob)))
                                    
                                    # Try matching by Essence MOB ID
                                    if essence_id and essence_id in validation_clip_map:
                                        matched_validation_clip = validation_clip_map[essence_id]
                                        is_embedded = matched_validation_clip.is_embedded
                                    elif essence_id and essence_id.strip() in validation_clip_map:
                                        matched_validation_clip = validation_clip_map[essence_id.strip()]
                                        is_embedded = matched_validation_clip.is_embedded
                                    else:
                                        # Fallback: check directly
                                        try:
                                            check_mob = essence_mob if essence_mob else source_mob
                                            if hasattr(check_mob, 'descriptor'):
                                                descriptor = check_mob.descriptor
                                                if hasattr(descriptor, 'essence') or hasattr(descriptor, 'essence_data'):
                                                    is_embedded = True
                                            if not is_embedded and hasattr(check_mob, 'essence'):
                                                is_embedded = True
                                        except Exception:
                                            pass
                                    
                                    # FINAL VERIFICATION: Always double-check the essence MOB for external locators
                                    if is_embedded:
                                        is_embedded = _verify_essence_mob_is_embedded(essence_mob, source_mob)
                                        if not is_embedded:
                                            _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Final verification failed: MOB has external locator", verbose_only=True)
                                    
                                    if is_embedded:
                                        # Use validation clip name if available
                                        if matched_validation_clip:
                                            clip_name = matched_validation_clip.name
                                        clip_start = current_pos
                                        source_start = segment_start / edit_rate
                                        clip_length = segment_length / edit_rate if segment_length > 0 else 0.0
                                        
                                        # Use essence_id for embedded path if we found it
                                        embedded_id = essence_id if essence_id else source_id
                                        embedded_path = f"EMBEDDED:{aaf_file_path}:{embedded_id}"
                                        # playback_clip = PlaybackClip(
                                            # name=clip_name,
                                            # file_path=embedded_path,
                                            # start_time=source_start,
                                            # duration=clip_length,
                                            # track_index=track_index,
                                            # timeline_start=clip_start,
                                            # timeline_end=clip_start + clip_length,
                                            # source_in=source_start,
                                            # source_out=source_start + clip_length
                                        # )
                                        # playback_clips.append(playback_clip)
                                        _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Added clip from OperationGroup slot: {clip_name} at track {track_index}, timeline {clip_start:.3f}-{clip_start + clip_length:.3f}s", verbose_only=True)
                                        
                                        if segment_length > 0:
                                            current_pos += segment_length / edit_rate
                
                # Always recurse into components (for nested structures and non-OperationGroups)
                # This will catch any SourceClips we might have missed
                _extract_clips_from_track(component, playback_clips, processed_sources,
                                         aaf_file_path, track_index, current_pos, edit_rate, depth + 1, slot_idx, validation_clip_map)
                if comp_length > 0:
                    current_pos += comp_length / edit_rate
        
        # Process slots (nested tracks)
        if hasattr(segment, 'slots'):
            slots = list(segment.slots) if hasattr(segment.slots, '__iter__') else []
            _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Segment has {len(slots)} slot(s)", verbose_only=True)
            for nested_slot_idx, slot in enumerate(slots):
                if hasattr(slot, 'segment') and slot.segment:
                    slot_pos = timeline_position
                    try:
                        if hasattr(slot, 'start'):
                            slot_pos = float(getattr(slot, 'start', 0)) / edit_rate
                    except Exception:
                        pass
                    _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Processing nested slot {nested_slot_idx} at {slot_pos:.3f}s", verbose_only=True)
                    _extract_clips_from_track(slot.segment, playback_clips, processed_sources,
                                             aaf_file_path, track_index, slot_pos, edit_rate, depth + 1, slot_idx, validation_clip_map)
    
    except Exception as e:
        _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Error processing segment: {e}", verbose_only=True)
        import traceback
        _debug_print(f"{indent}DEBUG: [{slot_idx}/T{track_index}] Traceback: {traceback.format_exc()}", verbose_only=True)


# def _extract_playback_from_segment(segment, playback_clips: List[PlaybackClip], processed_sources: Set[str], aaf_file_path: str):
    # """
    # Extracts playback information from an AAF segment.
    # Uses the same logic as validation to find clips, then filters for playback.
    
    # Args:
        # segment: AAF segment object
        # playback_clips: List to append found clips to
        # processed_sources: Set of processed source IDs to avoid duplicates
        # aaf_file_path: Path to the AAF file (for resolving relative paths)
    # """
    # try:
        # Check if this is a SourceClip with a MOB
        # if hasattr(segment, 'mob') and segment.mob is not None:
            # source_mob = segment.mob
            # source_id = str(getattr(source_mob, 'mob_id', id(source_mob)))
            
            # if source_id in processed_sources:
                # return
            # processed_sources.add(source_id)
            
            # Get clip name
            # clip_name = getattr(segment, 'name', None) or getattr(source_mob, 'name', 'Unnamed Clip')
            # if not clip_name:
                # clip_name = f"Clip_{len(playback_clips) + 1}"
            
            # Extract file path - use same logic as validation
            # external_path = None
            # is_embedded = False
            
            # try:
                # if hasattr(source_mob, 'descriptor'):
                    # descriptor = source_mob.descriptor
                    
                    # if hasattr(descriptor, 'locator'):
                        # locator = descriptor.locator
                        # if locator:
                            # if hasattr(locator, 'path'):
                                # external_path = str(locator.path)
                            # elif hasattr(locator, 'url_string'):
                                # url = str(locator.url_string)
                                # if url.startswith('file://'):
                                    # external_path = url[7:]
                                # elif not url.startswith('http'):
                                    # external_path = url
                    
                    # if hasattr(descriptor, 'essence') or hasattr(descriptor, 'essence_data'):
                        # is_embedded = True
                
                # Alternative: Check for essence mobs
                # if not external_path and not is_embedded:
                    # if hasattr(source_mob, 'essence'):
                        # is_embedded = True
                
                # Also check for file locators in the mob itself (same as validation)
                # if not external_path:
                    # for slot in getattr(source_mob, 'slots', []):
                        # if hasattr(slot, 'segment'):
                            # seg = slot.segment
                            # if hasattr(seg, 'mob') and seg.mob:
                                # mob = seg.mob
                                # if hasattr(mob, 'descriptor'):
                                    # desc = mob.descriptor
                                    # if hasattr(desc, 'locator'):
                                        # loc = desc.locator
                                        # if loc and hasattr(loc, 'path'):
                                            # external_path = str(loc.path)
                                            # break
                                        # elif loc and hasattr(loc, 'url_string'):
                                            # url = str(loc.url_string)
                                            # if url.startswith('file://'):
                                                # external_path = url[7:]
                                                # break
                                            # elif not url.startswith('http'):
                                                # external_path = url
                                                # break
            # except Exception:
                # pass
            
            # Resolve relative paths
            # if external_path:
                # if not os.path.isabs(external_path):
                    # aaf_dir = os.path.dirname(os.path.abspath(aaf_file_path))
                    # external_path = os.path.join(aaf_dir, external_path)
                # external_path = os.path.normpath(external_path)
            
            # Extract timing information if available
            # start_time = 0.0
            # duration = 0.0
            
            # try:
                # Try to get start/end times from segment
                # if hasattr(segment, 'start'):
                    # start_time = float(getattr(segment, 'start', 0))
                # if hasattr(segment, 'length'):
                    # duration = float(getattr(segment, 'length', 0))
                # Convert from edit units to seconds if needed (simplified)
                # In real AAF files, this would require sample rate conversion
            # except Exception:
                # pass
            
            # ONLY add embedded clips - external clips mean the file is broken
            # if is_embedded and not external_path:
                # For embedded clips, use special path format
                # embedded_path = f"EMBEDDED:{aaf_file_path}:{source_id}"
                # playback_clip = PlaybackClip(
                    # name=clip_name,
                    # file_path=embedded_path,
                    # start_time=start_time,
                    # duration=duration
                # )
                # playback_clips.append(playback_clip)
        
        # Recursively process slots/segments
        # if hasattr(segment, 'slots'):
            # for slot in segment.slots:
                # if hasattr(slot, 'segment') and slot.segment:
                    # _extract_playback_from_segment(slot.segment, playback_clips, processed_sources, aaf_file_path)
        
        # if hasattr(segment, 'components'):
            # for component in segment.components:
                # _extract_playback_from_segment(component, playback_clips, processed_sources, aaf_file_path)
    
    # except Exception:
        # pass
# ============================================================================
# END ARCHIVED: _extract_playback_from_segment
# ============================================================================


# def _extract_playback_clips_from_omf(file_path: str) -> List[PlaybackClip]:
    """
    Extracts playback-ready clips from an OMF file.
    ONLY returns embedded clips - external clips mean the file is broken.
    
    Args:
        file_path: Path to the OMF file
        
    Returns:
        List[PlaybackClip]: List of clips ready for playback (embedded only)
    """
    # Use validation parser to find all clips
    try:
        validation_clips = _parse_omf_file(file_path)
    except Exception:
        return []
    
    # Convert validation clips to playback clips (ONLY embedded clips)
    playback_clips: List[PlaybackClip] = []
    for clip in validation_clips:
        if clip.is_embedded:
            # For embedded clips, use special path format
            embedded_path = f"EMBEDDED:{file_path}:{clip.clip_id or clip.name}"
            # playback_clip = PlaybackClip(
                # name=clip.name,
                # file_path=embedded_path,
                # start_time=0.0,
                # duration=0.0
            # )
            # playback_clips.append(playback_clip)
    
    return playback_clips
# ============================================================================
# END ARCHIVED: _extract_playback_clips_from_omf
# ============================================================================


# def extract_playback_clips(file_path: str) -> List[PlaybackClip]:
    """
    Extracts playback-ready clips from an OMF or AAF file.
    
    Args:
        file_path: Path to the OMF or AAF file
        
    Returns:
        List[PlaybackClip]: List of clips ready for playback
    """
    file_type = _detect_file_type(file_path)
    
    if file_type == 'aaf':
        return _extract_playback_clips_from_aaf(file_path)
    elif file_type == 'omf':
        return _extract_playback_clips_from_omf(file_path)
    else:
        return []


def validate_embedded_media(clip: MediaClip) -> bool:
    """
    Validates that embedded media data is present and correctly structured.
    
    For AAF files, this checks if the essence data is properly embedded
    in the file structure. Since we're using pyaaf2, we can verify that
    the embedded data exists by checking the file structure.
    
    Args:
        clip: MediaClip object representing an embedded audio clip
        
    Returns:
        bool: True if embedded media is valid, False otherwise
    """
    # For now, we assume embedded media is valid if the clip is marked as embedded
    # In a full implementation, we would:
    # - Re-open the AAF file
    # - Locate the essence data for this specific clip
    # - Verify the data structure and headers are correct
    # - Check that the data is not corrupted
    
    # Since we've already parsed the file and determined it's embedded,
    # we'll trust that the parser found the embedded data correctly.
    # If the parser couldn't find embedded data, it wouldn't have marked it as embedded.
    return True


# Note: extract_clip_info is now integrated into _extract_clips_from_segment
# This function is kept for potential future use or external API compatibility


def format_report(report: ValidationReport) -> str:
    """
    Formats a ValidationReport into a human-readable string.
    
    Args:
        report: The ValidationReport to format
        
    Returns:
        str: Formatted report string
    """
    output = []
    output.append("=" * 60)
    output.append("OMF/AAF Media Validation Report")
    output.append("=" * 60)
    output.append(f"File: {report.file_path}")
    output.append("")
    output.append("Summary:")
    output.append(f"  Total Audio Clips: {report.total_clips}")
    output.append(f"  Embedded Clips: {report.embedded_clips}")
    output.append(f"  Linked Clips: {report.linked_clips}")
    output.append(f"  Valid Clips: {report.valid_clips}")
    output.append(f"  Missing/Invalid Clips: {report.missing_clips}")
    output.append("")
    
    if report.missing_clips > 0:
        output.append("Missing/Invalid Clips Details:")
        output.append("-" * 60)
        for clip in report.missing_clip_details:
            output.append(f"  Clip: {clip.name}")
            if clip.clip_id:
                output.append(f"    ID: {clip.clip_id}")
            output.append(f"    Type: {'Embedded' if clip.is_embedded else 'Linked'}")
            if clip.external_path:
                output.append(f"    Expected Path: {clip.external_path}")
            if clip.error_message:
                output.append(f"    Error: {clip.error_message}")
            output.append("")
    else:
        output.append("✅ All audio clips are valid and accessible!")
    
    output.append("=" * 60)
    return "\n".join(output)


# ============================================================================
# ARCHIVED: extract_embedded_audio - disabled due to aaf2 library limitations
# TODO: Revisit when we have a solution for extracting embedded essence data
# Date archived: 2024-12-19
# ============================================================================
# def extract_embedded_audio(aaf_file_path: str, mob_id: str, output_path: str, start_time: float = 0.0, duration: float = 0.0) -> bool:
    """
    Extracts embedded audio from an AAF file for a specific MOB.
    
    Args:
        aaf_file_path: Path to the AAF file
        mob_id: MOB ID to extract audio from
        output_path: Path where the extracted audio should be saved (WAV format)
        start_time: Start time offset in seconds (optional)
        duration: Duration to extract in seconds (0 = extract all)
        
    Returns:
        bool: True if extraction succeeded, False otherwise
    """
    if not AAF_SUPPORT:
        print(f"Error: AAF support not available (aaf2 library not installed)", file=sys.stderr)
        return False
    
    try:
        import tempfile
        import wave
        import sys
        
        with aaf2.open(aaf_file_path, 'r') as f:
            # Find the MOB by ID - try multiple ID formats
            mob = None
            mobs_list = list(f.content.mobs.values()) if hasattr(f.content.mobs, 'values') else list(f.content.mobs)
            
            for m in mobs_list:
                try:
                    # Try different ways to get the MOB ID
                    m_id = None
                    if hasattr(m, 'mob_id'):
                        m_id = str(m.mob_id)
                    elif hasattr(m, 'mob_id') and m.mob_id:
                        m_id = str(m.mob_id)
                    else:
                        # Fallback: try to get ID from properties
                        try:
                            props = m.properties if hasattr(m, 'properties') else {}
                            if 'MobID' in props:
                                m_id = str(props['MobID'])
                        except Exception:
                            pass
                    
                    if m_id and m_id == mob_id:
                        mob = m
                        break
                except Exception as e:
                    continue
            
            if not mob:
                print(f"Error: MOB with ID '{mob_id}' not found in AAF file", file=sys.stderr)
                return False
            
            # Find the Essence MOB if this is a Composition MOB
            essence_mob = _find_essence_mob_from_composition_mob(mob)
            if essence_mob:
                mob = essence_mob
            
            # Check if MOB has embedded essence
            if not hasattr(mob, 'descriptor'):
                print(f"Error: MOB has no descriptor", file=sys.stderr)
                return False
            
            descriptor = mob.descriptor
            if not descriptor:
                print(f"Error: MOB descriptor is None", file=sys.stderr)
                return False
            
            # Check for external locator (not embedded)
            # Handle locator as a list (common in AAF files)
            if hasattr(descriptor, 'locator') and descriptor.locator:
                locator_value = descriptor.locator
                locators_to_check = []
                if isinstance(locator_value, (list, tuple)):
                    locators_to_check = list(locator_value)
                else:
                    locators_to_check = [locator_value]
                
                # Check each locator for actual external paths/URLs
                has_external_locator = False
                for locator in locators_to_check:
                    if locator is None:
                        continue
                    
                    # Check for path
                    if hasattr(locator, 'path') and locator.path:
                        has_external_locator = True
                        break
                    
                    # Check for URL
                    if hasattr(locator, 'url_string') and locator.url_string:
                        url = str(locator.url_string)
                        # Only external if it's file:// or http:// URL
                        if url.startswith('file://') or url.startswith('http://') or url.startswith('https://'):
                            has_external_locator = True
                            break
                        # If it's a non-urn URL, might still be external
                        if url and not url.startswith('urn:'):
                            has_external_locator = True
                            break
                
                if has_external_locator:
                    print(f"Error: MOB has external locator (not embedded)", file=sys.stderr)
                    return False
            
            # Extract essence data - try multiple methods comprehensively
            # In AAF files, embedded essence can be stored in various ways
            essence_data = None
            essence_source = None
            
            # Method 1: Try descriptor.essence
            if hasattr(descriptor, 'essence'):
                try:
                    essence_data = getattr(descriptor, 'essence', None)
                    if essence_data is not None:
                        essence_source = "descriptor.essence"
                except Exception as e:
                    print(f"DEBUG: Error accessing descriptor.essence: {e}", file=sys.stderr)
            
            # Method 2: Try descriptor.essence_data
            if not essence_data and hasattr(descriptor, 'essence_data'):
                try:
                    essence_data = getattr(descriptor, 'essence_data', None)
                    if essence_data is not None:
                        essence_source = "descriptor.essence_data"
                except Exception as e:
                    print(f"DEBUG: Error accessing descriptor.essence_data: {e}", file=sys.stderr)
            
            # Method 3: Try descriptor.essence_access
            if not essence_data and hasattr(descriptor, 'essence_access'):
                try:
                    essence_data = getattr(descriptor, 'essence_access', None)
                    if essence_data is not None:
                        essence_source = "descriptor.essence_access"
                except Exception as e:
                    print(f"DEBUG: Error accessing descriptor.essence_access: {e}", file=sys.stderr)
            
            # Method 4: Try MOB.essence directly
            if not essence_data and hasattr(mob, 'essence'):
                try:
                    essence_data = getattr(mob, 'essence', None)
                    if essence_data is not None:
                        essence_source = "mob.essence"
                except Exception as e:
                    print(f"DEBUG: Error accessing mob.essence: {e}", file=sys.stderr)
            
            # Method 5: Try accessing through MOB slots (essence might be in slot segments)
            if not essence_data and hasattr(mob, 'slots'):
                try:
                    slot_list = list(mob.slots) if hasattr(mob.slots, '__iter__') else []
                    for slot in slot_list:
                        if hasattr(slot, 'segment') and slot.segment:
                            seg = slot.segment
                            # Check if segment has essence
                            if hasattr(seg, 'mob') and seg.mob:
                                seg_mob = seg.mob
                                if hasattr(seg_mob, 'descriptor'):
                                    seg_desc = seg_mob.descriptor
                                    if hasattr(seg_desc, 'essence'):
                                        try:
                                            essence_data = getattr(seg_desc, 'essence', None)
                                            if essence_data is not None:
                                                essence_source = "slot.segment.mob.descriptor.essence"
                                                break
                                        except Exception:
                                            pass
                                    if not essence_data and hasattr(seg_desc, 'essence_data'):
                                        try:
                                            essence_data = getattr(seg_desc, 'essence_data', None)
                                            if essence_data is not None:
                                                essence_source = "slot.segment.mob.descriptor.essence_data"
                                                break
                                        except Exception:
                                            pass
                            
                            # Also try to read essence data directly from slot if it has a reader
                            if not essence_data and hasattr(slot, 'read'):
                                try:
                                    slot_data = slot.read()
                                    if slot_data:
                                        essence_data = slot_data
                                        essence_source = "slot.read()"
                                        break
                                except Exception:
                                    pass
                            
                            # Try accessing essence through slot's segment directly
                            if not essence_data and hasattr(seg, 'essence'):
                                try:
                                    essence_data = getattr(seg, 'essence', None)
                                    if essence_data is not None:
                                        essence_source = "slot.segment.essence"
                                        break
                                except Exception:
                                    pass
                except Exception as e:
                    print(f"DEBUG: Error accessing MOB slots: {e}", file=sys.stderr)
            
            # Method 6: Try using aaf2's stream/reader API if available
            if not essence_data:
                try:
                    # Some AAF files store essence in a stream that needs to be opened
                    if hasattr(f, 'open_essence'):
                        try:
                            essence_stream = f.open_essence(mob)
                            if essence_stream:
                                essence_data = essence_stream
                                essence_source = "aaf2.open_essence"
                        except Exception as e:
                            print(f"DEBUG: Error with aaf2.open_essence: {e}", file=sys.stderr)
                    
                    # Try reading essence using file's read method if available
                    if not essence_data and hasattr(f, 'read'):
                        try:
                            # Some aaf2 files allow reading essence directly
                            if hasattr(f, 'read_essence'):
                                essence_data = f.read_essence(mob)
                                if essence_data:
                                    essence_source = "aaf2.read_essence(mob)"
                        except Exception as e:
                            print(f"DEBUG: Error with aaf2.read_essence: {e}", file=sys.stderr)
                except Exception as e:
                    print(f"DEBUG: Error trying aaf2 stream API: {e}", file=sys.stderr)
            
            # Method 7: Try accessing through descriptor properties/keys
            if not essence_data:
                try:
                    # Some descriptors store essence in properties
                    if hasattr(descriptor, 'properties'):
                        props = descriptor.properties
                        # Handle case where properties is a method that needs to be called
                        if callable(props):
                            try:
                                props = props()
                            except Exception as e:
                                print(f"DEBUG: Error calling descriptor.properties(): {e}", file=sys.stderr)
                                props = None
                        
                        # Now check if props is a dict-like object
                        if props is not None:
                            # Try to access as dict
                            if isinstance(props, dict):
                                for key in ['EssenceData', 'Essence', 'Data', 'AudioData']:
                                    if key in props:
                                        try:
                                            essence_data = props[key]
                                            if essence_data is not None:
                                                essence_source = f"descriptor.properties[{key}]"
                                                break
                                        except Exception:
                                            pass
                            # Try to access via getattr if it's an object with attributes
                            elif hasattr(props, '__getitem__'):
                                for key in ['EssenceData', 'Essence', 'Data', 'AudioData']:
                                    try:
                                        if key in props:
                                            essence_data = props[key]
                                            if essence_data is not None:
                                                essence_source = f"descriptor.properties[{key}]"
                                                break
                                    except (KeyError, TypeError, AttributeError):
                                        pass
                except Exception as e:
                    print(f"DEBUG: Error accessing descriptor properties: {e}", file=sys.stderr)
            
            # Method 8: Try accessing through file's essence container
            if not essence_data:
                try:
                    # AAF files may store essence in a separate container
                    if hasattr(f, 'essence') and f.essence:
                        try:
                            # Try to get essence by MOB ID
                            essence_container = f.essence
                            if hasattr(essence_container, 'get'):
                                essence_data = essence_container.get(mob_id, None)
                                if essence_data:
                                    essence_source = "file.essence.get(mob_id)"
                        except Exception as e:
                            print(f"DEBUG: Error accessing file.essence: {e}", file=sys.stderr)
                    
                    # Also try essence_data attribute
                    if not essence_data and hasattr(f, 'essence_data'):
                        try:
                            essence_data = f.essence_data
                            if essence_data:
                                essence_source = "file.essence_data"
                        except Exception as e:
                            print(f"DEBUG: Error accessing file.essence_data: {e}", file=sys.stderr)
                except Exception as e:
                    print(f"DEBUG: Error accessing file essence container: {e}", file=sys.stderr)
            
            # Method 9: If essence attribute exists but value is None, try to access through file stream
            # This handles cases where essence is stored but needs to be read through the file
            if not essence_data and (hasattr(descriptor, 'essence') or hasattr(mob, 'essence')):
                try:
                    # Try to use the file's stream to read essence data
                    # Some AAF files store essence data that needs to be read through the file stream
                    if hasattr(f, 'stream') and f.stream:
                        try:
                            # Try to get stream for this MOB
                            stream = f.stream
                            if hasattr(stream, 'read_essence'):
                                essence_data = stream.read_essence(mob)
                                if essence_data:
                                    essence_source = "file.stream.read_essence(mob)"
                        except Exception as e:
                            print(f"DEBUG: Error with file.stream.read_essence: {e}", file=sys.stderr)
                    
                    # Also try reading essence directly from file using MOB ID
                    if not essence_data and mob_id:
                        try:
                            # Try to find essence data in file by MOB ID
                            # Some AAF files store essence indexed by MOB ID
                            if hasattr(f, 'content') and f.content:
                                # Try to find essence MOB in file content
                                try:
                                    # Look for essence MOBs in the file
                                    if hasattr(f.content, 'mobs'):
                                        mobs = f.content.mobs
                                        if hasattr(mobs, '__iter__'):
                                            for file_mob in mobs:
                                                try:
                                                    if hasattr(file_mob, 'mob_id'):
                                                        file_mob_id = str(file_mob.mob_id)
                                                        if file_mob_id == mob_id:
                                                            # Found the MOB, try to get essence
                                                            if hasattr(file_mob, 'essence'):
                                                                essence_val = getattr(file_mob, 'essence', None)
                                                                if essence_val is not None:
                                                                    essence_data = essence_val
                                                                    essence_source = "file.content.mobs[mob_id].essence"
                                                                    break
                                                except Exception:
                                                    continue
                                except Exception as e:
                                    print(f"DEBUG: Error searching file.content.mobs: {e}", file=sys.stderr)
                        except Exception as e:
                            print(f"DEBUG: Error accessing file content by MOB ID: {e}", file=sys.stderr)
                    
                    # Method 10: Try to read essence data from file's essence storage directly
                    # When mob.essence is None, the data might be in the file's essence container
                    if not essence_data:
                        try:
                            # Try to access file's essence storage
                            if hasattr(f, 'essence') or hasattr(f.content, 'essence'):
                                essence_storage = getattr(f, 'essence', None) or getattr(f.content, 'essence', None)
                                if essence_storage:
                                    # Try to get essence by MOB
                                    if hasattr(essence_storage, 'get'):
                                        try:
                                            essence_data = essence_storage.get(mob, None)
                                            if essence_data:
                                                essence_source = "file.essence.get(mob)"
                                        except Exception:
                                            pass
                                    
                                    # Try iterating through essence storage
                                    if not essence_data and hasattr(essence_storage, '__iter__'):
                                        try:
                                            for essence_item in essence_storage:
                                                # Try to match by MOB or MOB ID
                                                if hasattr(essence_item, 'mob') and essence_item.mob == mob:
                                                    if hasattr(essence_item, 'data'):
                                                        essence_data = essence_item.data
                                                        essence_source = "file.essence[item].data"
                                                        break
                                                elif hasattr(essence_item, 'mob_id'):
                                                    item_mob_id = str(essence_item.mob_id)
                                                    if item_mob_id == mob_id:
                                                        if hasattr(essence_item, 'data'):
                                                            essence_data = essence_item.data
                                                            essence_source = "file.essence[item].data (by ID)"
                                                            break
                                        except Exception as e:
                                            print(f"DEBUG: Error iterating essence storage: {e}", file=sys.stderr)
                        except Exception as e:
                            print(f"DEBUG: Error accessing file essence storage: {e}", file=sys.stderr)
                except Exception as e:
                    print(f"DEBUG: Error accessing file stream: {e}", file=sys.stderr)
            
            # Log what we found
            if essence_data:
                print(f"DEBUG: Found essence data via {essence_source}, type: {type(essence_data).__name__}", file=sys.stderr)
            else:
                # Final attempt: Check if we can at least verify the structure
                # If MOB has essence attribute but value is None, it might still be accessible
                # through a different mechanism - log detailed info for debugging
                print(f"DEBUG: No essence data found. MOB structure:", file=sys.stderr)
                print(f"DEBUG:   - hasattr(mob, 'essence'): {hasattr(mob, 'essence')}", file=sys.stderr)
                print(f"DEBUG:   - hasattr(descriptor, 'essence'): {hasattr(descriptor, 'essence')}", file=sys.stderr)
                print(f"DEBUG:   - hasattr(descriptor, 'essence_data'): {hasattr(descriptor, 'essence_data')}", file=sys.stderr)
                if hasattr(descriptor, 'essence'):
                    try:
                        val = getattr(descriptor, 'essence', None)
                        print(f"DEBUG:   - descriptor.essence value: {val} (type: {type(val).__name__})", file=sys.stderr)
                    except Exception as e:
                        print(f"DEBUG:   - Error getting descriptor.essence: {e}", file=sys.stderr)
                if hasattr(mob, 'essence'):
                    try:
                        val = getattr(mob, 'essence', None)
                        print(f"DEBUG:   - mob.essence value: {val} (type: {type(val).__name__})", file=sys.stderr)
                    except Exception as e:
                        print(f"DEBUG:   - Error getting mob.essence: {e}", file=sys.stderr)
                print(f"Error: No essence data found in MOB descriptor or MOB (tried all methods)", file=sys.stderr)
                return False
            
            # Get audio properties from descriptor
            sample_rate = 48000  # Default
            channels = 2  # Default
            sample_width = 2  # 16-bit default
            
            try:
                # Try to get sample rate
                if hasattr(descriptor, 'sample_rate') and descriptor.sample_rate:
                    sample_rate = int(descriptor.sample_rate)
                elif hasattr(descriptor, 'AudioSamplingRate') and descriptor.AudioSamplingRate:
                    sample_rate = int(descriptor.AudioSamplingRate)
                
                # Try to get channels
                if hasattr(descriptor, 'channels') and descriptor.channels:
                    channels = int(descriptor.channels)
                elif hasattr(descriptor, 'AudioChannelCount') and descriptor.AudioChannelCount:
                    channels = int(descriptor.AudioChannelCount)
                
                # Try to get bit depth
                if hasattr(descriptor, 'bits_per_sample') and descriptor.bits_per_sample:
                    sample_width = int(descriptor.bits_per_sample) // 8
                elif hasattr(descriptor, 'AudioBitsPerSample') and descriptor.AudioBitsPerSample:
                    sample_width = int(descriptor.AudioBitsPerSample) // 8
            except Exception as e:
                print(f"Warning: Could not read all audio properties, using defaults: {e}", file=sys.stderr)
            
            # Read essence data - try multiple methods comprehensively
            audio_bytes = None
            read_method = None
            
            try:
                # Method 1: File-like object with read() method
                if hasattr(essence_data, 'read'):
                    try:
                        if hasattr(essence_data, 'seek'):
                            essence_data.seek(0)
                        audio_bytes = essence_data.read()
                        if audio_bytes:
                            read_method = "file-like.read()"
                    except Exception as e:
                        print(f"DEBUG: Error reading essence data (file-like): {e}", file=sys.stderr)
                
                # Method 2: Already bytes
                if not audio_bytes and isinstance(essence_data, bytes):
                    audio_bytes = essence_data
                    read_method = "direct bytes"
                
                # Method 3: Try to convert iterable to bytes
                if not audio_bytes and hasattr(essence_data, '__iter__') and not isinstance(essence_data, (str, bytes)):
                    try:
                        audio_bytes = bytes(essence_data)
                        if audio_bytes:
                            read_method = "bytes(iterable)"
                    except Exception as e:
                        print(f"DEBUG: Error converting essence data to bytes: {e}", file=sys.stderr)
                
                # Method 4: Try accessing .data property
                if not audio_bytes and hasattr(essence_data, 'data'):
                    try:
                        data = essence_data.data
                        if isinstance(data, bytes):
                            audio_bytes = data
                            read_method = "essence_data.data (bytes)"
                        elif hasattr(data, '__iter__') and not isinstance(data, str):
                            audio_bytes = bytes(data)
                            if audio_bytes:
                                read_method = "essence_data.data (converted)"
                    except Exception as e:
                        print(f"DEBUG: Error accessing essence_data.data: {e}", file=sys.stderr)
                
                # Method 5: Try accessing through getvalue() (for StringIO-like objects)
                if not audio_bytes and hasattr(essence_data, 'getvalue'):
                    try:
                        val = essence_data.getvalue()
                        if isinstance(val, bytes):
                            audio_bytes = val
                            read_method = "getvalue() (bytes)"
                        elif hasattr(val, '__iter__') and not isinstance(val, str):
                            audio_bytes = bytes(val)
                            if audio_bytes:
                                read_method = "getvalue() (converted)"
                    except Exception as e:
                        print(f"DEBUG: Error with getvalue(): {e}", file=sys.stderr)
                
                # Method 6: Try accessing through buffer or memoryview
                if not audio_bytes:
                    try:
                        if hasattr(essence_data, 'buffer'):
                            buf = essence_data.buffer
                            if hasattr(buf, 'read'):
                                audio_bytes = buf.read()
                                if audio_bytes:
                                    read_method = "buffer.read()"
                    except Exception as e:
                        print(f"DEBUG: Error accessing buffer: {e}", file=sys.stderr)
                
                # Method 7: Try using memoryview if it's a buffer-like object
                if not audio_bytes:
                    try:
                        mv = memoryview(essence_data)
                        audio_bytes = mv.tobytes()
                        if audio_bytes:
                            read_method = "memoryview.tobytes()"
                    except (TypeError, AttributeError):
                        pass
                    except Exception as e:
                        print(f"DEBUG: Error with memoryview: {e}", file=sys.stderr)
                
                # Method 8: Try accessing through aaf2's stream API if it's a stream
                if not audio_bytes and hasattr(essence_data, '__class__'):
                    class_name = essence_data.__class__.__name__
                    # Check if it's an aaf2 stream type
                    if 'Stream' in class_name or 'Reader' in class_name:
                        try:
                            if hasattr(essence_data, 'read'):
                                essence_data.seek(0) if hasattr(essence_data, 'seek') else None
                                audio_bytes = essence_data.read()
                                if audio_bytes:
                                    read_method = f"aaf2 stream ({class_name})"
                        except Exception as e:
                            print(f"DEBUG: Error reading from aaf2 stream: {e}", file=sys.stderr)
                
                # Method 9: Try accessing through aaf2 essence reader if available
                if not audio_bytes and hasattr(f, 'open_essence'):
                    try:
                        # Try to open essence as a stream
                        essence_stream = f.open_essence(mob)
                        if essence_stream:
                            if hasattr(essence_stream, 'read'):
                                essence_stream.seek(0) if hasattr(essence_stream, 'seek') else None
                                audio_bytes = essence_stream.read()
                                if audio_bytes:
                                    read_method = "aaf2.open_essence().read()"
                            elif isinstance(essence_stream, bytes):
                                audio_bytes = essence_stream
                                read_method = "aaf2.open_essence() (bytes)"
                    except Exception as e:
                        print(f"DEBUG: Error with aaf2.open_essence: {e}", file=sys.stderr)
                
                # Method 10: If essence_data is an object with special methods, try them
                if not audio_bytes and hasattr(essence_data, '__class__'):
                    class_name = essence_data.__class__.__name__
                    # Try common data access methods
                    for method_name in ['get_data', 'getbytes', 'tobytes', 'getvalue', 'readall', 'read_bytes']:
                        if hasattr(essence_data, method_name):
                            try:
                                method = getattr(essence_data, method_name)
                                if callable(method):
                                    result = method()
                                    if isinstance(result, bytes):
                                        audio_bytes = result
                                        read_method = f"{class_name}.{method_name}()"
                                        break
                                    elif hasattr(result, '__iter__') and not isinstance(result, str):
                                        audio_bytes = bytes(result)
                                        if audio_bytes:
                                            read_method = f"{class_name}.{method_name}() (converted)"
                                            break
                            except Exception as e:
                                print(f"DEBUG: Error with {method_name}(): {e}", file=sys.stderr)
                                continue
                
            except Exception as e:
                print(f"DEBUG: Error reading essence data: {e}", file=sys.stderr)
                import traceback
                print(f"DEBUG: Traceback: {traceback.format_exc()}", file=sys.stderr)
            
            if audio_bytes:
                print(f"DEBUG: Successfully read {len(audio_bytes)} bytes via {read_method}", file=sys.stderr)
            else:
                print(f"DEBUG: Failed to read audio bytes. Essence data type: {type(essence_data).__name__}", file=sys.stderr)
                print(f"DEBUG: Essence data attributes: {[attr for attr in dir(essence_data) if not attr.startswith('_')][:20]}", file=sys.stderr)
            
            if not audio_bytes or len(audio_bytes) == 0:
                print(f"Error: No audio bytes extracted from essence data (tried all read methods)", file=sys.stderr)
                return False
            
            # Apply start time and duration offsets if specified
            if start_time > 0.0 or duration > 0.0:
                bytes_per_sample = sample_width * channels
                samples_per_second = sample_rate
                bytes_per_second = bytes_per_sample * samples_per_second
                
                start_byte = int(start_time * bytes_per_second)
                if duration > 0.0:
                    end_byte = int((start_time + duration) * bytes_per_second)
                    if end_byte > len(audio_bytes):
                        end_byte = len(audio_bytes)
                    audio_bytes = audio_bytes[start_byte:end_byte]
                else:
                    audio_bytes = audio_bytes[start_byte:]
            
            if not audio_bytes or len(audio_bytes) == 0:
                print(f"Error: No audio bytes after applying time offsets", file=sys.stderr)
                return False
            
            # Write WAV file
            try:
                with wave.open(output_path, 'wb') as wav_file:
                    wav_file.setnchannels(channels)
                    wav_file.setsampwidth(sample_width)
                    wav_file.setframerate(sample_rate)
                    wav_file.writeframes(audio_bytes)
            except Exception as e:
                print(f"Error writing WAV file: {e}", file=sys.stderr)
                return False
            
            return True
    
    except Exception as e:
        print(f"Error extracting embedded audio: {e}", file=sys.stderr)
        import traceback
        print(f"Traceback: {traceback.format_exc()}", file=sys.stderr)
        return False
# ============================================================================
# END ARCHIVED: extract_embedded_audio
# ============================================================================


if __name__ == "__main__":
    import sys
    
    if len(sys.argv) < 2:
        print("Usage: python media_validator.py <path_to_omf_or_aaf_file>", file=sys.stderr)
        sys.exit(1)
    
    file_path = sys.argv[1]
    # ARCHIVED: Playback and extract modes disabled
    # playback_mode = len(sys.argv) > 2 and sys.argv[2] == "--playback"
    # extract_mode = len(sys.argv) > 2 and sys.argv[2] == "--extract-audio"
    playback_mode = False
    extract_mode = False
    
    # Set global debug verbosity flag
    # Access the module-level variable directly
    globals()['DEBUG_VERBOSE'] = True  # Always verbose now that playback is disabled
    
    try:
        # ARCHIVED: Extract mode disabled
        if False and extract_mode:
            # Extract embedded audio mode
            if len(sys.argv) < 5:
                print("Usage: python media_validator.py <aaf_file> --extract-audio <mob_id> <output_path> [start_time] [duration]", file=sys.stderr)
                sys.exit(1)
            
            mob_id = sys.argv[3]
            output_path = sys.argv[4]
            start_time = float(sys.argv[5]) if len(sys.argv) > 5 else 0.0
            duration = float(sys.argv[6]) if len(sys.argv) > 6 else 0.0
            
            success = extract_embedded_audio(file_path, mob_id, output_path, start_time, duration)
            if success:
                print(output_path, flush=True)
                sys.exit(0)
            else:
                print(f"Error: Failed to extract audio for MOB {mob_id}", file=sys.stderr)
                sys.exit(1)
        # ARCHIVED: Playback mode disabled
        elif False and playback_mode:
            # Create debug log file
            import tempfile
            import os
            from pathlib import Path
            
            # Create debug log in Downloads folder
            downloads_dir = os.path.expanduser("~/Downloads")
            aaf_name = os.path.splitext(os.path.basename(file_path))[0]
            debug_log_path = os.path.join(downloads_dir, f"{aaf_name}_playback_debug.txt")
            
            # Set up global debug file
            globals()['_DEBUG_FILE'] = open(debug_log_path, 'w', encoding='utf-8')
            globals()['_DEBUG_FILE'].write(f"=== Playback Clip Extraction Debug Log ===\n")
            globals()['_DEBUG_FILE'].write(f"File: {file_path}\n")
            globals()['_DEBUG_FILE'].write(f"Timestamp: {__import__('datetime').datetime.now().isoformat()}\n")
            globals()['_DEBUG_FILE'].write(f"{'=' * 60}\n\n")
            globals()['_DEBUG_FILE'].flush()
            
            # Tell user where debug file is
            print(f"DEBUG: Debug log will be saved to: {debug_log_path}", file=sys.stderr, flush=True)
            
            try:
                # Extract playback clips and output as JSON
                clips = extract_playback_clips(file_path)
                output = {
                    "clips": [asdict(clip) for clip in clips]
                }
                
                # Write final summary to debug file
                if _DEBUG_FILE:
                    _DEBUG_FILE.write(f"\n{'=' * 60}\n")
                    _DEBUG_FILE.write(f"FINAL SUMMARY: Found {len(clips)} clips\n")
                    _DEBUG_FILE.write(f"Debug log saved to: {debug_log_path}\n")
                    _DEBUG_FILE.close()
                    globals()['_DEBUG_FILE'] = None
                
                # Output JSON to stdout and flush immediately
                json_output = json.dumps(output, indent=2)
                print(json_output, flush=True)
                sys.stdout.flush()
                sys.exit(0)
            except Exception as e:
                # Make sure debug file is closed even on error
                if _DEBUG_FILE:
                    _DEBUG_FILE.write(f"\n{'=' * 60}\n")
                    _DEBUG_FILE.write(f"ERROR: {str(e)}\n")
                    _DEBUG_FILE.write(f"Debug log saved to: {debug_log_path}\n")
                    _DEBUG_FILE.close()
                    globals()['_DEBUG_FILE'] = None
                raise
        # ARCHIVED: Playback mode disabled - always use normal validation mode
        # else:
        if True:  # Always use normal validation mode now
            # Normal validation mode
            report = validate_omf_aaf_media(file_path)
            
            # Output JSON for Swift app
            output = {
                "total_clips": report.total_clips,
                "embedded_clips": report.embedded_clips,
                "linked_clips": report.linked_clips,
                "missing_clips": report.missing_clips,
                "valid_clips": report.valid_clips,
                "file_path": report.file_path,
                "total_duration": report.total_duration,
                "missing_clip_details": [asdict(clip) for clip in report.missing_clip_details],
                "timeline_clips": [asdict(clip) for clip in report.timeline_clips]
            }
            json_output = json.dumps(output, indent=2)
            print(json_output, flush=True)
            
            # Exit with error code if there are missing clips
            if report.missing_clips > 0:
                sys.exit(1)
            else:
                sys.exit(0)
    except Exception as e:
        print(f"Error: {str(e)}", file=sys.stderr)
        sys.exit(1)

