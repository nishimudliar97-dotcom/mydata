def normalize_relative_path(stage_name, full_path):
    path = str(full_path).strip()

    if path.startswith("@"):
        path = path[1:]

    # remove full stage name if present
    full_stage_prefix = f"{stage_name}/"
    if path.lower().startswith(full_stage_prefix.lower()):
        path = path[len(full_stage_prefix):]

    # remove only last stage object name if present, e.g. TEST_A/
    short_stage_name = stage_name.split(".")[-1]
    short_stage_prefix = f"{short_stage_name}/"
    if path.lower().startswith(short_stage_prefix.lower()):
        path = path[len(short_stage_prefix):]

    return path
