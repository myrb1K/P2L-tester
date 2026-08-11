#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  // Vynutit skutečné GPU, ne adaptér přiřazený k displeji.
  //
  // Na headless serveru (bez monitoru) kreslí Windows do virtuálního displeje
  // — u zákazníka „USB Mobile Monitor Virtual Display“ (usbmmidd, instaluje
  // ho RustDesk). Bez preference si engine vezme adaptér toho displeje, na
  // kterém okno leží, a ten virtuální plnohodnotný Direct3D 11 device
  // nenabídne. ANGLE pak nevytvoří renderovací plochu a okno zůstane prázdné
  // (bílá plocha v původní velikosti, po maximalizaci zbytek černý).
  //
  // HighPerformancePreference řekne DXGI, ať vybere výkonný adaptér; virtuální
  // displej-only adaptéry jdou dolů, takže se použije fyzická grafika i když
  // na ní není zapojený monitor. Na strojích s jedinou grafikou se nic nemění.
  project.set_gpu_preference(flutter::GpuPreference::HighPerformancePreference);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"P2L Tester", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
