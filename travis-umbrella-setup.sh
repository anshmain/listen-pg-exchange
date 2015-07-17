#!/bin/bash
BUILD_DIR=${BUILD_DIR:-${HOME}/rabbitmq-public-umbrella}
RABBIT_TAG=${RABBIT_TAG:-v3_5_3}
echo "Build dir: ${BUILD_DIR}"
echo "Travis build dir: ${TRAVIS_BUILD_DIR}"

if [ -d $BUILD_DIR ]; then
    rm -rf $BUILD_DIR
fi
git clone https://github.com/rabbitmq/rabbitmq-public-umbrella.git $BUILD_DIR
cd $BUILD_DIR
git checkout -b rabbitmq_${RABBIT_TAG}
git pull origin rabbitmq_${RABBIT_TAG}
make co
git clone https://github.com/gmr/epgsql-wrapper.git
cp -r ${TRAVIS_BUILD_DIR} ${BUILD_DIR}/
