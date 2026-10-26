cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "native_audio.cc"
  "platform_bridge.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

apply_standard_settings(${BINARY_NAME})

add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)
find_package(Threads REQUIRED)
target_link_libraries(${BINARY_NAME} PRIVATE Threads::Threads ${CMAKE_DL_LIBS})

pkg_check_modules(PULSE REQUIRED libpulse)
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}" ${PULSE_INCLUDE_DIRS})
target_compile_options(${BINARY_NAME} PRIVATE ${PULSE_CFLAGS_OTHER})
