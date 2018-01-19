#!/bin/bash
set -e

LOCAL_TAG="v4.14.190"
UPSTREAM_TAG="v4.14.191"

echo "从 $LOCAL_TAG 合并到 $UPSTREAM_TAG 的所有新commit"

COMMITS=$(git rev-list --reverse ${LOCAL_TAG}..${UPSTREAM_TAG})

for COMMIT in $COMMITS; do
    echo "Cherry-picking commit $COMMIT ..."
    git cherry-pick --no-edit $COMMIT || {
        echo "冲突，自动用上游版本覆盖解决..."
        git checkout --theirs .
        git add .
        git cherry-pick --continue --no-edit
    }
done

echo "全部commit应用完毕！"
