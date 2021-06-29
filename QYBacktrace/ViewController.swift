//
//  ViewController.swift
//  QYBacktrace
//
//  Created by Joey on 2021/6/29.
//

import UIKit

class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        
        let button = UIButton(frame: CGRect(x: 150, y: 200, width: 100, height: 100))
        button.backgroundColor = .red
        button.setTitle("test", for: .normal)
        button.addTarget(self, action: #selector(btnClicked), for: .touchUpInside)

        view.addSubview(button)
    }
    
    @objc func btnClicked() {
        DispatchQueue.global().async {
            let symbals = Backtrace.backtraceAllThread()
            print(symbals)
        }

        animals()
    }
    
    func animals() {
        tiger()
    }
    
    func tiger() {
        simba()
    }
    
    func simba() {
        while true {
            
        }
    }

}

