// Copyright 2016 The Tulsi Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation


/// Provides functionality to generate an Xcode project from a TulsiGeneratorConfig.
final class XcodeProjectGenerator {
  enum Error: ErrorType {
    /// General Xcode project creation failure with associated debug info.
    case SerializationFailed(String)

    /// The given labels failed to resolve to valid targets.
    case LabelResolutionFailed(Set<BuildLabel>)
  }

  /// Path relative to PROJECT_FILE_PATH in which Tulsi generated files (scripts, artifacts, etc...)
  /// should be placed.
  private static let TulsiArtifactDirectory = ".tulsi"
  static let ScriptDirectorySubpath = "\(TulsiArtifactDirectory)/Scripts"
  static let ConfigDirectorySubpath = "\(TulsiArtifactDirectory)/Configs"
  static let ManifestFileSubpath = "\(TulsiArtifactDirectory)/generatorManifest.json"
  private static let BuildScript = "bazel_build.py"
  private static let CleanScript = "bazel_clean.sh"
  private static let EnvScript = "bazel_env.sh"

  private let workspaceRootURL: NSURL
  private let config: TulsiGeneratorConfig
  private let localizedMessageLogger: LocalizedMessageLogger
  private let fileManager: NSFileManager
  private let workspaceInfoExtractor: BazelWorkspaceInfoExtractorProtocol
  private let buildScriptURL: NSURL
  private let envScriptURL: NSURL
  private let cleanScriptURL: NSURL
  private let tulsiVersion: String

  private let pbxTargetGeneratorType: PBXTargetGeneratorProtocol.Type

  // Exposed for testing. Simply writes the given NSData to the given NSURL.
  var writeDataHandler: (NSURL, NSData) throws -> Void = { (outputFileURL: NSURL, data: NSData) in
    try data.writeToURL(outputFileURL, options: NSDataWritingOptions.DataWritingAtomic)
  }

  // Exposed for testing. Suppresses writing any preprocessor defines integral to Bazel itself into
  // the generated project.
  var suppressCompilerDefines = false

  // Exposed for testing. Suppresses creating folders for artifacts that are expected to be
  // generated by Bazel.
  var suppressGeneratedArtifactFolderCreation = false

  init(workspaceRootURL: NSURL,
       config: TulsiGeneratorConfig,
       localizedMessageLogger: LocalizedMessageLogger,
       workspaceInfoExtractor: BazelWorkspaceInfoExtractorProtocol,
       buildScriptURL: NSURL,
       envScriptURL: NSURL,
       cleanScriptURL: NSURL,
       tulsiVersion: String,
       fileManager: NSFileManager = NSFileManager.defaultManager(),
       pbxTargetGeneratorType: PBXTargetGeneratorProtocol.Type = PBXTargetGenerator.self) {
    self.workspaceRootURL = workspaceRootURL
    self.config = config
    self.localizedMessageLogger = localizedMessageLogger
    self.workspaceInfoExtractor = workspaceInfoExtractor
    self.buildScriptURL = buildScriptURL
    self.envScriptURL = envScriptURL
    self.cleanScriptURL = cleanScriptURL
    self.tulsiVersion = tulsiVersion
    self.fileManager = fileManager
    self.pbxTargetGeneratorType = pbxTargetGeneratorType
  }

  /// Generates an Xcode project bundle in the given folder.
  /// NOTE: This may be a long running operation.
  func generateXcodeProjectInFolder(outputFolderURL: NSURL) throws -> NSURL {
    let generateProfilingToken = localizedMessageLogger.startProfiling("generating_project")
    defer { localizedMessageLogger.logProfilingEnd(generateProfilingToken) }
    try resolveConfigReferences()

    let mainGroup = pbxTargetGeneratorType.mainGroupForOutputFolder(outputFolderURL,
                                                                    workspaceRootURL: workspaceRootURL)
    let projectInfo = try buildXcodeProjectWithMainGroup(mainGroup)

    let serializingProgressNotifier = ProgressNotifier(name: SerializingXcodeProject,
                                                       maxValue: 1,
                                                       indeterminate: true)
    let serializer = OpenStepSerializer(rootObject: projectInfo.project,
                                        gidGenerator: ConcreteGIDGenerator())

    let serializingProfileToken = localizedMessageLogger.startProfiling("serializing_project")
    guard let serializedXcodeProject = serializer.serialize() else {
      throw Error.SerializationFailed("OpenStep serialization failed")
    }
    localizedMessageLogger.logProfilingEnd(serializingProfileToken)

    let projectBundleName = config.xcodeProjectFilename
    let projectURL = outputFolderURL.URLByAppendingPathComponent(projectBundleName)
    if !createDirectory(projectURL) {
      throw Error.SerializationFailed("Project directory creation failed")
    }
    let pbxproj = projectURL.URLByAppendingPathComponent("project.pbxproj")
    try writeDataHandler(pbxproj, serializedXcodeProject)
    serializingProgressNotifier.incrementValue()

    try installWorkspaceSettings(projectURL)
    try installXcodeSchemesForProjectInfo(projectInfo,
                                          projectURL: projectURL,
                                          projectBundleName: projectBundleName)
    installTulsiScripts(projectURL)
    installGeneratorConfig(projectURL)
    createGeneratedArtifactFolders(mainGroup, relativeTo: projectURL)

    let manifestFileURL = projectURL.URLByAppendingPathComponent(XcodeProjectGenerator.ManifestFileSubpath,
                                                                 isDirectory: false)
    let manifest = GeneratorManifest(localizedMessageLogger: localizedMessageLogger,
                                     pbxProject: projectInfo.project)
    manifest.writeToURL(manifestFileURL)

    return projectURL
  }

  // MARK: - Private methods

  /// Encapsulates information about the results of a buildXcodeProjectWithMainGroup invocation.
  private struct GeneratedProjectInfo {
    /// The newly created PBXProject instance.
    let project: PBXProject

    /// RuleEntry's for which build targets were created. Note that this list may differ from the
    /// set of targets selected by the user as part of the generator config.
    let buildRuleEntries: Set<RuleEntry>

    /// RuleEntry's for test_suite's for whichspecial test schemes should be created.
    let testSuiteRuleEntries: Set<RuleEntry>

    /// Map of buildRuleEntries to generated indexer targets containing the sources on which each
    /// build rule depends. This map may be used to link a given build rule to its associated
    /// indexers (e.g., for Live issues support).
    let buildRuleToIndexerTargets: [RuleEntry: Set<PBXTarget>]
  }

  /// Invokes Bazel to load any missing information in the config file.
  private func resolveConfigReferences() throws {
    let resolvedLabels = loadRuleEntryMap()
    let unresolvedLabels = config.buildTargetLabels.filter() { resolvedLabels[$0] == nil }
    if !unresolvedLabels.isEmpty {
      throw Error.LabelResolutionFailed(Set<BuildLabel>(unresolvedLabels))
    }
  }

  // Generates a PBXProject and a returns it along with a set of
  private func buildXcodeProjectWithMainGroup(mainGroup: PBXGroup) throws -> GeneratedProjectInfo {
    let xcodeProject = PBXProject(name: config.projectName, mainGroup: mainGroup)
    if let enabled = config.options[.SuppressSwiftUpdateCheck].commonValueAsBool where enabled {
      xcodeProject.lastSwiftUpdateCheck = "0710"
    }

    let buildScriptPath = "${PROJECT_FILE_PATH}/\(XcodeProjectGenerator.ScriptDirectorySubpath)/\(XcodeProjectGenerator.BuildScript)"
    let cleanScriptPath = "${PROJECT_FILE_PATH}/\(XcodeProjectGenerator.ScriptDirectorySubpath)/\(XcodeProjectGenerator.CleanScript)"
    let envScriptPath = "${PROJECT_FILE_PATH}/\(XcodeProjectGenerator.ScriptDirectorySubpath)/\(XcodeProjectGenerator.EnvScript)"

    let generator = pbxTargetGeneratorType.init(bazelURL: config.bazelURL,
                                                bazelBinPath: workspaceInfoExtractor.bazelBinPath,
                                                project: xcodeProject,
                                                buildScriptPath: buildScriptPath,
                                                envScriptPath: envScriptPath,
                                                tulsiVersion: tulsiVersion,
                                                options: config.options,
                                                localizedMessageLogger: localizedMessageLogger,
                                                workspaceRootURL: workspaceRootURL,
                                                suppressCompilerDefines: suppressCompilerDefines)

    if let additionalFilePaths = config.additionalFilePaths {
      generator.generateFileReferencesForFilePaths(additionalFilePaths)
    }

    let ruleEntryMap = loadRuleEntryMap()
    var expandedTargetLabels = Set<BuildLabel>()
    var testSuiteRules = Set<RuleEntry>()
    // Swift 2.1 segfaults when dealing with nested functions using generics of any type, so an
    // unnecessary type conversion from an array to a set is done instead.
    func expandTargetLabels(labels: Set<BuildLabel>) {
      for label in labels {
        guard let ruleEntry = ruleEntryMap[label] else { continue }
        if ruleEntry.type != "test_suite" {
          expandedTargetLabels.insert(label)
        } else {
          testSuiteRules.insert(ruleEntry)
          expandTargetLabels(ruleEntry.weakDependencies)
        }
      }
    }
    expandTargetLabels(Set<BuildLabel>(config.buildTargetLabels))
    // TODO(abaire): Revert to the generic implementation below when Swift 2.1 support is dropped.
//    func expandTargetLabels<T: SequenceType where T.Generator.Element == BuildLabel>(labels: T) {
//      for label in labels {
//        guard let ruleEntry = ruleEntryMap[label] else { continue }
//        if ruleEntry.type != "test_suite" {
//          expandedTargetLabels.insert(label)
//        } else {
//          testSuiteRules.insert(ruleEntry)
//          expandTargetLabels(ruleEntry.weakDependencies)
//        }
//      }
//    }
//    expandTargetLabels(config.buildTargetLabels)

    var targetRules = Set<RuleEntry>()
    var targetIndexers = [RuleEntry: Set<PBXTarget>]()
    var hostTargetLabels = [BuildLabel: BuildLabel]()

    func profileAction(name: String, @noescape action: () throws -> Void) rethrows {
      let profilingToken = localizedMessageLogger.startProfiling(name)
      try action()
      localizedMessageLogger.logProfilingEnd(profilingToken)
    }

    profileAction("generating_indexers") {
      let progressNotifier = ProgressNotifier(name: GeneratingIndexerTargets,
                                              maxValue: expandedTargetLabels.count)
      for label in expandedTargetLabels {
        progressNotifier.incrementValue()
        guard let ruleEntry = ruleEntryMap[label] else {
          localizedMessageLogger.error("UnknownTargetRule",
                                       comment: "Failure to look up a Bazel target that was expected to be present. The target label is %1$@",
                                       values: label.value)
          continue
        }
        targetRules.insert(ruleEntry)
        for hostTargetLabel in ruleEntry.linkedTargetLabels {
          hostTargetLabels[hostTargetLabel] = ruleEntry.label
        }
        let indexers = generator.generateIndexerTargetsForRuleEntry(ruleEntry,
                                                                    ruleEntryMap: ruleEntryMap,
                                                                    pathFilters: config.pathFilters)
        targetIndexers[ruleEntry] = indexers
      }
    }

    // Generate RuleEntry's for any test hosts to ensure that selected tests can be executed in
    // Xcode.
    for (hostLabel, testLabel) in hostTargetLabels {
      if config.buildTargetLabels.contains(hostLabel) { continue }
      localizedMessageLogger.warning("GeneratingTestHost",
                                     comment: "Warning to show when a user has selected an XCTest (%2$@) but not its host application (%1$@), resulting in an automated target generation which may have issues.",
                                     values: hostLabel.value, testLabel.value)
      targetRules.insert(RuleEntry(label: hostLabel,
                                   type: "_test_host_",
                                   attributes: [:],
                                   sourceFiles: [],
                                   nonARCSourceFiles: [],
                                   dependencies: Set(),
                                   frameworkImports: [],
                                   secondaryArtifacts: []))
    }

    let workingDirectory = pbxTargetGeneratorType.workingDirectoryForPBXGroup(mainGroup)
    profileAction("generating_clean_target") {
      generator.generateBazelCleanTarget(cleanScriptPath, workingDirectory: workingDirectory)
    }
    profileAction("generating_top_level_build_configs") {
      generator.generateTopLevelBuildConfigurations()
    }

    try profileAction("generating_build_targets") {
      try generator.generateBuildTargetsForRuleEntries(targetRules)
    }

    profileAction("patching_external_repository_references") {
      patchExternalRepositoryReferences(xcodeProject)
    }
    return GeneratedProjectInfo(project: xcodeProject,
                                buildRuleEntries: targetRules,
                                testSuiteRuleEntries: testSuiteRules,
                                buildRuleToIndexerTargets: targetIndexers)
  }

  // Examines the given xcodeProject, patching any groups that were generated under Bazel's magical
  // "external" container to absolute filesystem references.
  private func patchExternalRepositoryReferences(xcodeProject: PBXProject) {
    let mainGroup = xcodeProject.mainGroup
    guard let externalGroup = mainGroup.childGroupsByName["external"] else { return }
    let externalChildren = externalGroup.children as! [PBXGroup]
    for child in externalChildren {
      guard let resolvedPath = workspaceInfoExtractor.resolveExternalReferencePath("external/\(child.path!)") else {
        localizedMessageLogger.warning("ExternalRepositoryResolutionFailed",
                                       comment: "Failed to look up a valid filesystem path for the external repository group given as %1$@. The project should work correctly, but any files inside of the cited group will be unavailable.",
                                       values: child.path!)
        continue
      }

      let newChild = mainGroup.getOrCreateChildGroupByName("@\(child.name)",
                                                           path: resolvedPath,
                                                           sourceTree: .Absolute)
      newChild.serializesName = true
      newChild.migrateChildrenOfGroup(child)
    }
    mainGroup.removeChild(externalGroup)
  }

  private func installWorkspaceSettings(projectURL: NSURL) throws {
    // Write workspace options if they don't already exist.
    let workspaceSharedDataURL = projectURL.URLByAppendingPathComponent("project.xcworkspace/xcshareddata")
    let workspaceSettingsURL = workspaceSharedDataURL.URLByAppendingPathComponent("WorkspaceSettings.xcsettings")
    if !fileManager.fileExistsAtPath(workspaceSettingsURL.path!) &&
        createDirectory(workspaceSharedDataURL) {
      let workspaceSettings = ["IDEWorkspaceSharedSettings_AutocreateContextsIfNeeded": false]
      let data = try NSPropertyListSerialization.dataWithPropertyList(workspaceSettings,
                                                                      format: .XMLFormat_v1_0,
                                                                      options: 0)
      try writeDataHandler(workspaceSettingsURL, data)
    }
  }

  private func loadRuleEntryMap() -> [BuildLabel: RuleEntry] {
    return workspaceInfoExtractor.ruleEntriesForLabels(config.buildTargetLabels,
                                                       startupOptions: config.options[.BazelBuildStartupOptionsDebug],
                                                       buildOptions: config.options[.BazelBuildOptionsDebug])
  }

  // Writes Xcode schemes for non-indexer targets if they don't already exist.
  private func installXcodeSchemesForProjectInfo(info: GeneratedProjectInfo,
                                                 projectURL: NSURL,
                                                 projectBundleName: String) throws {
    let xcschemesURL = projectURL.URLByAppendingPathComponent("xcshareddata/xcschemes")
    guard createDirectory(xcschemesURL) else { return }

    func targetForLabel(label: BuildLabel) -> PBXTarget? {
      if let pbxTarget = info.project.targetByName[label.targetName!] {
        return pbxTarget
      } else if let pbxTarget = info.project.targetByName[label.asFullPBXTargetName!] {
        return pbxTarget
      }
      return nil
    }

    let runTestTargetBuildConfigPrefix = pbxTargetGeneratorType.getRunTestTargetBuildConfigPrefix()
    for entry in info.buildRuleEntries {
      // Generate an XcodeScheme with a test action set up to allow tests to be run without Xcode
      // attempting to compile code.
      let target: PBXTarget
      if let pbxTarget = targetForLabel(entry.label) {
        target = pbxTarget
      } else {
        localizedMessageLogger.warning("XCSchemeGenerationFailed",
                                       comment: "Warning shown when generation of an Xcode scheme failed for build target %1$@",
                                       values: entry.label.value)
        continue
      }

      let filename = target.name + ".xcscheme"
      let url = xcschemesURL.URLByAppendingPathComponent(filename)
      let indexerTargets = info.buildRuleToIndexerTargets[entry] ?? []
      let scheme = XcodeScheme(target: target,
                               indexerTargets: indexerTargets,
                               project: info.project,
                               projectBundleName: projectBundleName,
                               testActionBuildConfig: runTestTargetBuildConfigPrefix + "Debug")
      let xmlDocument = scheme.toXML()

      let data = xmlDocument.XMLDataWithOptions(NSXMLNodePrettyPrint)
      try writeDataHandler(url, data)
    }

    func installSchemeForTestSuite(suite: RuleEntry, named suiteName: String) throws {
      var suiteHostTarget: PBXTarget? = nil
      var validTests = Set<PBXTarget>()
      for testEntryLabel in suite.weakDependencies {
        guard let testTarget = targetForLabel(testEntryLabel) else {
          localizedMessageLogger.warning("TestSuiteUsesUnresolvedTarget",
                                         comment: "Warning shown when a test_suite %1$@ refers to a test label %2$@ that was not resolved and will be ignored",
                                         values: suite.label.value, testEntryLabel.value)
          continue
        }
        guard let testHostTarget = info.project.linkedHostForTestTarget(testTarget) as? PBXNativeTarget else {
          localizedMessageLogger.warning("TestSuiteTestHostResolutionFailed",
                                         comment: "Warning shown when the test host for a test %1$@ inside test suite %2$@ could not be found. The test will be ignored, but this state is unexpected and should be reported.",
                                         values: testEntryLabel.value, suite.label.value)
          continue
        }
        // The first target host is arbitrarily chosen as the scheme target.
        if suiteHostTarget == nil {
          suiteHostTarget = testHostTarget
        }
        validTests.insert(testTarget)
      }

      guard let concreteTarget = suiteHostTarget else {
        localizedMessageLogger.warning("TestSuiteHasNoValidTests",
                                       comment: "Warning shown when none of the tests of a test suite %1$@ were able to be resolved.",
                                       values: suite.label.value)
        return
      }
      let filename = suiteName + "_Suite.xcscheme"
      let url = xcschemesURL.URLByAppendingPathComponent(filename)
      let indexerTargets = info.buildRuleToIndexerTargets[suite] ?? []
      let scheme = XcodeScheme(target: concreteTarget,
                               indexerTargets: indexerTargets,
                               project: info.project,
                               projectBundleName: projectBundleName,
                               testActionBuildConfig: runTestTargetBuildConfigPrefix + "Debug",
                               explicitTests: Array(validTests))
      let xmlDocument = scheme.toXML()

      let data = xmlDocument.XMLDataWithOptions(NSXMLNodePrettyPrint)
      try writeDataHandler(url, data)
    }

    var testSuiteSchemes = [String: [RuleEntry]]()
    for entry in info.testSuiteRuleEntries {
      let shortName = entry.label.targetName!
      if let _ = testSuiteSchemes[shortName] {
        testSuiteSchemes[shortName]!.append(entry)
      } else {
        testSuiteSchemes[shortName] = [entry]
      }
    }
    for testSuites in testSuiteSchemes.values {
      for suite in testSuites {
        let suiteName: String
        if testSuites.count > 1 {
          suiteName = suite.label.asFullPBXTargetName!
        } else {
          suiteName = suite.label.targetName!
        }
        try installSchemeForTestSuite(suite, named: suiteName)
      }
    }
  }

  private func installTulsiScripts(projectURL: NSURL) {
    let scriptDirectoryURL = projectURL.URLByAppendingPathComponent(XcodeProjectGenerator.ScriptDirectorySubpath,
                                                                    isDirectory: true)
    if createDirectory(scriptDirectoryURL) {
      let progressNotifier = ProgressNotifier(name: InstallingScripts, maxValue: 1)
      defer { progressNotifier.incrementValue() }
      localizedMessageLogger.infoMessage("Installing scripts")
      installFiles([(buildScriptURL, XcodeProjectGenerator.BuildScript),
                    (cleanScriptURL, XcodeProjectGenerator.CleanScript),
                    (envScriptURL, XcodeProjectGenerator.EnvScript),
                   ],
                   toDirectory: scriptDirectoryURL)
    }
  }

  private func installGeneratorConfig(projectURL: NSURL) {
    let configDirectoryURL = projectURL.URLByAppendingPathComponent(XcodeProjectGenerator.ConfigDirectorySubpath,
                                                                    isDirectory: true)
    guard createDirectory(configDirectoryURL, failSilently: true) else { return }
    let progressNotifier = ProgressNotifier(name: InstallingGeneratorConfig, maxValue: 1)
    defer { progressNotifier.incrementValue() }
    localizedMessageLogger.infoMessage("Installing generator config")

    let configURL = configDirectoryURL.URLByAppendingPathComponent(config.defaultFilename)
    var errorInfo: String? = nil
    do {
      let data = try config.save()
      try writeDataHandler(configURL, data)
    } catch let e as NSError {
      errorInfo = e.localizedDescription
    } catch {
      errorInfo = "Unexpected exception"
    }
    if let errorInfo = errorInfo {
      localizedMessageLogger.infoMessage("Generator config serialization failed. \(errorInfo)")
      return
    }

    let perUserConfigURL = configDirectoryURL.URLByAppendingPathComponent(TulsiGeneratorConfig.perUserFilename)
    errorInfo = nil
    do {
      if let data = try config.savePerUserSettings() {
        try writeDataHandler(perUserConfigURL, data)
      }
    } catch let e as NSError {
      errorInfo = e.localizedDescription
    } catch {
      errorInfo = "Unexpected exception"
    }
    if let errorInfo = errorInfo {
      localizedMessageLogger.infoMessage("Generator per-user config serialization failed. \(errorInfo)")
      return
    }
  }

  private func createDirectory(resourceDirectoryURL: NSURL, failSilently: Bool = false) -> Bool {
    do {
      try fileManager.createDirectoryAtURL(resourceDirectoryURL,
                                           withIntermediateDirectories: true,
                                           attributes: nil)
    } catch let e as NSError {
      if !failSilently {
        localizedMessageLogger.error("DirectoryCreationFailed",
                                     comment: "Failed to create an important directory. The resulting project will most likely be broken. A bug should be reported.",
                                     values: resourceDirectoryURL, e.localizedDescription)
      }
      return false
    }
    return true
  }

  private func installFiles(files: [(sourceURL: NSURL, filename: String)],
                            toDirectory directory: NSURL, failSilently: Bool = false) {
    for (sourceURL, filename) in files {
      guard let targetURL = NSURL(string: filename, relativeToURL: directory) else {
        if !failSilently {
          localizedMessageLogger.error("CopyingResourceFailed",
                                       comment: "Failed to copy an important file resource, the resulting project will most likely be broken. A bug should be reported.",
                                       values: sourceURL, filename, "Target URL is invalid")
        }
        continue
      }

      let errorInfo: String?
      do {
        if fileManager.fileExistsAtPath(targetURL.path!) {
          try fileManager.removeItemAtURL(targetURL)
        }
        try fileManager.copyItemAtURL(sourceURL, toURL: targetURL)
        errorInfo = nil
      } catch let e as NSError {
        errorInfo = e.localizedDescription
      } catch {
        errorInfo = "Unexpected exception"
      }
      if !failSilently, let errorInfo = errorInfo {
        localizedMessageLogger.error("CopyingResourceFailed",
                                     comment: "Failed to copy an important file resource, the resulting project will most likely be broken. A bug should be reported.",
                                     values: sourceURL, targetURL.absoluteString, errorInfo)
      }
    }
  }

  private func createGeneratedArtifactFolders(mainGroup: PBXGroup, relativeTo path: NSURL) {
    if suppressGeneratedArtifactFolderCreation { return }
    let generatedArtifacts = mainGroup.allSources.filter() { !$0.isInputFile }
    var generatedFolders = Set<NSURL>()
    for artifact in generatedArtifacts {
      let url = path.URLByAppendingPathComponent(artifact.sourceRootRelativePath)
      if let absoluteURL = url.URLByDeletingLastPathComponent?.URLByStandardizingPath {
        generatedFolders.insert(absoluteURL)
      }
    }

    var failedCreates = [String]()
    for url in generatedFolders {
      if !createDirectory(url, failSilently: true) {
        failedCreates.append(url.path!)
      }
    }
    if !failedCreates.isEmpty {
      localizedMessageLogger.warning("CreatingGeneratedArtifactFoldersFailed",
                                     comment: "Failed to create folders for generated artifacts %1$@. The generated Xcode project may need to be reloaded after the first build.",
                                     values: failedCreates.joinWithSeparator(", "))
    }
  }


  /// Encapsulates high level information about the generated Xcode project intended for use by
  /// external scripts or to aid debugging.
  private class GeneratorManifest {
    private let localizedMessageLogger: LocalizedMessageLogger
    private let pbxProject: PBXProject
    var fileReferences: [String]! = nil
    var targets: [String]! = nil
    var artifacts: [String]! = nil

    init(localizedMessageLogger: LocalizedMessageLogger, pbxProject: PBXProject) {
      self.localizedMessageLogger = localizedMessageLogger
      self.pbxProject = pbxProject
    }

    func writeToURL(outputURL: NSURL) -> Bool {
      if fileReferences == nil {
        parsePBXProject()
      }
      let dict = [
          "fileReferences": fileReferences,
          "targets": targets,
          "artifacts": artifacts,
      ]
      do {
        let data = try NSJSONSerialization.tulsi_newlineTerminatedDataWithJSONObject(dict,
                                                                                     options: .PrettyPrinted)
        return data.writeToURL(outputURL, atomically: true)
      } catch let e as NSError {
        localizedMessageLogger.infoMessage("Failed to write manifest file \(outputURL.path!): \(e.localizedDescription)")
        return false
      } catch {
        localizedMessageLogger.infoMessage("Failed to write manifest file \(outputURL.path!): Unexpected exception")
        return false
      }
    }

    private func parsePBXProject() {
      fileReferences = []
      targets = []
      artifacts = []

      for ref in pbxProject.mainGroup.allSources {
        if ref.isInputFile {
          fileReferences.append(ref.sourceRootRelativePath)
        } else {
          artifacts.append(ref.sourceRootRelativePath)
        }
      }

      for target in pbxProject.allTargets {
        targets.append(target.name)
      }
    }
  }
}
