//
//  MainTestView.swift
//  TrollFools
//

import CocoaLumberjackSwift
import SwiftUI
import UniformTypeIdentifiers

struct MainTestView: View {
    @StateObject private var viewModel = DylibTestViewModel()
    @State private var isImporterPresented = false
    @State private var isLogsPresented = false

    private var currentLogFileURL: URL? {
        let fileLogger = DDLog.allLoggers.compactMap { $0 as? DDFileLogger }.first
        if let logFilePath = fileLogger?.currentLogFileInfo?.filePath {
            return URL(fileURLWithPath: logFilePath)
        }
        return nil
    }

    private var allowedTypes: [UTType] {
        var types: [UTType] = [.bundle, .framework, .package, .zip, .data]
        if let dylibType = UTType(filenameExtension: "dylib") {
            types.append(dylibType)
        }
        if let debType = UTType(filenameExtension: "deb") {
            types.append(debType)
        }
        return types
    }

    var body: some View {
        NavigationView {
            VStack {
                // แถบแสดงสถานะ
                HStack {
                    if viewModel.isLoading {
                        ProgressView()
                            .padding(.trailing, 5)
                    }
                    Text(viewModel.statusMessage)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(10)
                .padding(.horizontal)

                // ลิสต์แสดงรายการ Dylib
                List {
                    Section(header: Text("Dylibs / Frameworks ที่นำเข้าไว้")) {
                        if viewModel.items.isEmpty {
                            Text("ยังไม่มีไฟล์ที่นำเข้า กดปุ่ม '+' ด้านบนเพื่อเพิ่ม")
                                .font(.footnote)
                                .foregroundColor(.gray)
                        } else {
                            ForEach(viewModel.items) { item in
                                HStack {
                                    Image(
                                        systemName: item.type == .dylib
                                            ? "shippingbox.fill"
                                            : "cube.transparent.fill"
                                    )
                                    .foregroundColor(.accentColor)
                                    .font(.title2)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.name)
                                            .font(.body)
                                            .fontWeight(.medium)
                                        Text(
                                            item.isLoaded
                                                ? "Status: Loaded (dlopen)"
                                                : "Status: Not Loaded"
                                        )
                                        .font(.caption)
                                        .foregroundColor(
                                            item.isLoaded ? .green : .gray
                                        )
                                    }

                                    Spacer()

                                    Button(action: {
                                        viewModel.toggleLoad(item: item)
                                    }) {
                                        Text(item.isLoaded ? "Unload" : "Load")
                                            .font(.subheadline)
                                            .fontWeight(.bold)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(
                                                item.isLoaded
                                                    ? Color.red.opacity(0.15)
                                                    : Color.blue.opacity(0.15)
                                            )
                                            .foregroundColor(
                                                item.isLoaded ? .red : .blue
                                            )
                                            .cornerRadius(8)
                                    }
                                    .buttonStyle(BorderlessButtonStyle())
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                .listStyle(InsetGroupedListStyle())
            }
            .navigationTitle("Test Dylib Loader")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { isLogsPresented = true }) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.title3)
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { isImporterPresented = true }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .disabled(viewModel.isLoading)
                }
            }
            .onAppear {
                viewModel.refreshList()
            }
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: allowedTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let selectedURL = urls.first else { return }
                    viewModel.importAndLoad(from: selectedURL)
                case .failure(let error):
                    viewModel.statusMessage =
                        "เกิดข้อผิดพลาด: \(error.localizedDescription)"
                }
            }
            .sheet(isPresented: $isLogsPresented) {
                if let logURL = currentLogFileURL {
                    InlineLogsView(url: logURL)
                } else {
                    NavigationView {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.orange)
                            Text("ไม่พบไฟล์ Log ล่าสุด")
                                .font(.headline)
                            Text("ลองรันกระบวนการเพื่อสร้าง Log ขึ้นมาก่อน")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                        .navigationTitle("Logs")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button("ปิด") { isLogsPresented = false }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Local LogsView Wrapper (ป้องกัน Error Target Scope ใน CLI)

struct InlineLogsView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let viewController = StripedTextTableViewController(path: url.path)

        viewController.autoReload = false
        viewController.maximumNumberOfRows = 1000
        viewController.maximumNumberOfLines = 20
        viewController.reversed = true
        viewController.allowDismissal = true
        viewController.allowTrash = false
        viewController.allowSearch = true
        viewController.allowShare = true
        viewController.allowMultiline = true
        viewController.pullToReload = false
        viewController.tapToCopy = true
        viewController.pressToCopy = true
        viewController.preserveEmptyLines = false
        viewController.removeDuplicates = true

        if let regex = try? NSRegularExpression(
            pattern: "^\\d{4}\\/\\d{2}\\/\\d{2} \\d{2}:\\d{2}:\\d{2}:\\d{3}  "
        ) {
            viewController.rowPrefixRegularExpression = regex
        }

        return UINavigationController(rootViewController: viewController)
    }

    func updateUIViewController(
        _ uiViewController: UINavigationController,
        context: Context
    ) {}
}
