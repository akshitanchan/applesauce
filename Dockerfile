# Linux image for MCP directories that check servers in Docker (for example Glama).
# applesauce works only on macOS. In this image it starts, lists its tools, and every call
# answers UNSUPPORTED_PLATFORM, so nothing pretends to work.
FROM swift:6.1-noble AS build
WORKDIR /src
COPY . .
RUN swift build -c release --product applesauce --static-swift-stdlib

# The slim Swift image has the system libraries Foundation needs on Linux (libcurl, libxml2).
FROM swift:6.1-noble-slim
COPY --from=build /src/.build/release/applesauce /usr/local/bin/applesauce
ENTRYPOINT ["applesauce"]
