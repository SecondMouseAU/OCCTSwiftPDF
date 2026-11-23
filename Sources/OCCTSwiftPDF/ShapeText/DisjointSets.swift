// DisjointSets.swift
// OCCTSwiftPDF
//
// Grouping by a relation: the sets that shapes near one another make.

/// A union-find over `0..<count`.
struct DisjointSets {
    private var parent: [Int]

    init(count: Int) { parent = Array(0..<count) }

    mutating func find(_ index: Int) -> Int {
        var root = index
        while parent[root] != root { root = parent[root] }
        var walk = index
        while parent[walk] != root {
            let next = parent[walk]
            parent[walk] = root
            walk = next
        }
        return root
    }

    mutating func union(_ a: Int, _ b: Int) {
        let (ra, rb) = (find(a), find(b))
        if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
    }
}
