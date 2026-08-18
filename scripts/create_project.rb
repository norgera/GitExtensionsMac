#!/usr/bin/env ruby

require "xcodeproj"

root = File.expand_path("..", __dir__)
project_path = File.join(root, "GitExtensionsMac.xcodeproj")
project = Xcodeproj::Project.new(project_path)
target = project.new_target(:application, "GitExtensionsMac", :osx, "13.0")
graph_test_target = project.new_target(:command_line_tool, "RevisionGraphLayoutTests", :osx, "13.0")

source_root = project.main_group.new_group("GitExtensionsMac", "GitExtensionsMac")
source_references = {}

Dir.glob(File.join(root, "GitExtensionsMac", "**", "*.swift")).sort.each do |absolute_path|
  relative_path = absolute_path.delete_prefix(File.join(root, "GitExtensionsMac") + "/")
  components = relative_path.split("/")
  file_name = components.pop
  group = components.reduce(source_root) do |current, component|
    current.groups.find { |candidate| candidate.display_name == component } || current.new_group(component, component)
  end
  reference = group.new_file(file_name)
  target.source_build_phase.add_file_reference(reference)
  source_references[relative_path] = reference
end

graph_test_target.source_build_phase.add_file_reference(source_references.fetch("Models/RepositoryModels.swift"))
graph_test_target.source_build_phase.add_file_reference(source_references.fetch("Models/RevisionGraphLayout.swift"))
graph_test_target.source_build_phase.add_file_reference(source_references.fetch("Models/ContextMenuState.swift"))
graph_test_target.source_build_phase.add_file_reference(source_references.fetch("Git/GitRepositoryMutations.swift"))
tests_root = project.main_group.new_group("Tests", "Tests")
graph_test_target.source_build_phase.add_file_reference(tests_root.new_file("RevisionGraphLayoutTests.swift"))
graph_test_target.source_build_phase.add_file_reference(tests_root.new_file("ContextMenuStateTests.swift"))
graph_test_target.source_build_phase.add_file_reference(tests_root.new_file("GitRepositoryMutationTests.swift"))

resource_root = project.main_group.new_group("Resources", "GitExtensionsMac/Resources")
Dir.glob(File.join(root, "GitExtensionsMac", "Resources", "**", "*.png")).sort.each do |absolute_path|
  reference = resource_root.new_file(absolute_path.delete_prefix(File.join(root, "GitExtensionsMac", "Resources") + "/"))
  target.resources_build_phase.add_file_reference(reference)
end

target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.gitextensions.mac"
  settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
  settings["GENERATE_INFOPLIST_FILE"] = "YES"
  settings["INFOPLIST_KEY_CFBundleDisplayName"] = "Git Extensions"
  settings["INFOPLIST_KEY_LSApplicationCategoryType"] = "public.app-category.developer-tools"
  settings["MACOSX_DEPLOYMENT_TARGET"] = "13.0"
  settings["SWIFT_VERSION"] = "5.0"
  settings["SWIFT_EMIT_LOC_STRINGS"] = "YES"
  settings["CODE_SIGN_STYLE"] = "Automatic"
  settings["COMBINE_HIDPI_IMAGES"] = "YES"
end

graph_test_target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.gitextensions.mac.graph-tests"
  settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
  settings["MACOSX_DEPLOYMENT_TARGET"] = "13.0"
  settings["SWIFT_VERSION"] = "5.0"
  settings["CODE_SIGNING_ALLOWED"] = "NO"
end

project.build_configurations.each do |configuration|
  configuration.build_settings["MACOSX_DEPLOYMENT_TARGET"] = "13.0"
end

project.save
