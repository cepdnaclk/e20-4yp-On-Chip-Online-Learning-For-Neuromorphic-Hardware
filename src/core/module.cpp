#include "core/module.h"
#include <iostream>
#include <string>

namespace nomad {

uint32_t Module::next_id_ = 0;

Module::Module(const std::string& name)
    : name_(name), id_(next_id_++) {}

void Module::add_child(Module* child) {
    children_.push_back(child);
}

void Module::print_hierarchy(int indent) const {
    for (int i = 0; i < indent; ++i) std::cout << "  ";
    std::cout << "[" << id_ << "] " << name_ << "\n";
    for (const auto* child : children_) {
        child->print_hierarchy(indent + 1);
    }
}

}  // namespace nomad
