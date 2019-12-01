#!/bin/sh

get_tbb_path() (
    Path=tbb/build
    cd tbb
    Path=${Path}/$(make info | grep prefix | sed -E 's_(.+)=(.+)_\2_')_release
    echo $Path
)

export LD_LIBRARY_PATH=$(get_tbb_path)
File=$1
shift
./$File $@
